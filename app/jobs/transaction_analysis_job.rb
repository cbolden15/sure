class TransactionAnalysisJob < ApplicationJob
  include BillsHelper

  queue_as :medium_priority

  retry_on Timeout::Error, Net::OpenTimeout, Net::ReadTimeout, wait: 5.seconds, attempts: 3 do |job, error|
    job.send(:fail_run!, job.arguments.first, error)
  end

  def perform(run_id)
    run = TransactionAnalysis::Run.find_by(id: run_id)
    return unless run
    return unless claim!(run)

    broadcast(run)
    TransactionAnalysis::Runner.new(run: run).call
    broadcast(run.reload)
  rescue Timeout::Error, Net::OpenTimeout, Net::ReadTimeout => error
    capture_error(run, error, retrying: true)
    raise
  rescue => error
    fail_run!(run_id, error)
  end

  private
    def claim!(run)
      run.with_lock do
        return true if executions > 1 && run.running?
        return false unless run.pending?

        run.update!(status: :running, error_message: nil)
        true
      end
    end

    def fail_run!(run_id, error)
      run = run_id.is_a?(TransactionAnalysis::Run) ? run_id : TransactionAnalysis::Run.find_by(id: run_id)
      return unless run

      run.with_lock do
        if run.pending? || run.running? || run.awaiting_clarification?
          run.update!(status: :failed, error_message: "Analysis could not be completed. Please try again.")
        end
      end
      capture_error(run, error)
      broadcast(run.reload)
    end

    def capture_error(run, error, retrying: false)
      return unless run

      DebugLogEntry.capture(
        category: "transaction_analysis_error",
        level: "error",
        message: "Transaction analysis run failed#{' and will retry' if retrying}: #{error.class}",
        source: self.class.name,
        provider_key: run.provider_id,
        user: run.transaction_analysis.user,
        family: run.transaction_analysis.user.family,
        metadata: { run_id: run.id, error_class: error.class.name, retrying: retrying }
      )
    end

    def broadcast(run)
      Current.set(session: Session.new(user: run.transaction_analysis.user)) do
        ai_configured = bills_one_shot_ai_available?
        html = ApplicationController.renderer.render(
          partial: "transaction_analyses/run",
          locals: { run: run, analysis: run.transaction_analysis, ai_configured: ai_configured }
        )
        Turbo::StreamsChannel.broadcast_replace_to(
          [ run.transaction_analysis, :runs ],
          target: ActionView::RecordIdentifier.dom_id(run),
          html: html
        )
      end
    rescue StandardError => error
      Rails.logger.warn("Transaction analysis broadcast failed: #{error.class}")
    end
end
