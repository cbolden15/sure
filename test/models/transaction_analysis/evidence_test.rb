require "test_helper"

class TransactionAnalysis::EvidenceTest < ActiveSupport::TestCase
  test "requires a unique opaque citation token per run" do
    evidence = TransactionAnalysis::Evidence.find_by!(citation_token: "E1")

    duplicate = evidence.run.evidences.build(citation_token: evidence.citation_token, snapshot: { "merchant" => "Other" })

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:citation_token], "has already been taken"
  end

  test "rejects unsafe snapshots and changes to completed-run evidence" do
    evidence = TransactionAnalysis::Evidence.find_by!(citation_token: "E1")
    unsafe_evidence = TransactionAnalysis::Evidence.new(
      run: evidence.run,
      citation_token: "E2",
      snapshot: { "notes" => "Private detail" }
    )

    assert_not unsafe_evidence.valid?
    assert_includes unsafe_evidence.errors[:snapshot], "contains unsupported fields"
    assert_includes unsafe_evidence.errors[:run], "is completed and immutable"
    assert_not evidence.destroy
  end

  test "rejects nested snapshot values and stale or reassigned completed evidence" do
    user = users(:family_admin)
    analysis = user.transaction_analyses.create!(title: "Mutable until complete")
    run = TransactionAnalysis::Run.create_pending!(analysis: analysis, user: user, prompt: "Review spending")
    evidence = run.evidences.create!(citation_token: "E2", snapshot: { "merchant" => "Coffee shop" })
    stale_evidence = TransactionAnalysis::Evidence.find(evidence.id)
    run.update!(status: :running)
    run.complete!

    nested_snapshot = stale_evidence.dup
    nested_snapshot.citation_token = "E3"
    nested_snapshot.snapshot = { "merchant" => { "notes" => "Private detail" } }
    assert_not nested_snapshot.valid?
    assert_includes nested_snapshot.errors[:snapshot], "values must be scalar"

    assert_not stale_evidence.update(snapshot: { "merchant" => "Changed" })
    assert_includes stale_evidence.errors[:run], "is completed and immutable"
    assert_not stale_evidence.destroy

    pending_run = TransactionAnalysis::Run.create_pending!(analysis: analysis, user: user, prompt: "Another review")
    stale_evidence.run = pending_run
    assert_not stale_evidence.valid?
    assert_includes stale_evidence.errors[:run], "is completed and immutable"
  end

  test "destroys completed-run evidence when its analysis is deleted" do
    user = users(:family_admin)
    analysis = user.transaction_analyses.create!(title: "Disposable analysis")
    run = TransactionAnalysis::Run.create_pending!(analysis: analysis, user: user, prompt: "Review spending")
    evidence = run.evidences.create!(citation_token: "E2", snapshot: { "merchant" => "Coffee shop" })
    run.update!(status: :running)
    run.complete!

    assert_difference("TransactionAnalysis::Evidence.count", -1) { analysis.destroy! }
    assert_not TransactionAnalysis::Evidence.exists?(evidence.id)
  end

  test "rejects an evidence save that crosses the run limit after validation" do
    user = users(:family_admin)
    analysis = user.transaction_analyses.create!(title: "Evidence capacity")
    run = TransactionAnalysis::Run.create_pending!(analysis: analysis, user: user, prompt: "Review spending")

    24.times do |index|
      run.evidences.create!(citation_token: "E#{index + 1}", snapshot: { "merchant" => "Merchant #{index}" })
    end
    candidate = run.evidences.build(citation_token: "E26", snapshot: { "merchant" => "Candidate" })

    assert_predicate candidate, :valid?
    run.evidences.create!(citation_token: "E25", snapshot: { "merchant" => "Final allowed" })

    assert_raises(ActiveRecord::RecordInvalid) { candidate.save!(validate: false) }
    assert_equal TransactionAnalysis::Evidence::MAXIMUM_PER_RUN, run.evidences.reload.count
  end

  test "rejects reassignment into a full run with or without validations" do
    user = users(:family_admin)
    analysis = user.transaction_analyses.create!(title: "Evidence reassignment")
    source_run = TransactionAnalysis::Run.create_pending!(analysis: analysis, user: user, prompt: "Source")
    target_run = TransactionAnalysis::Run.create_pending!(analysis: analysis, user: user, prompt: "Target")
    evidence = source_run.evidences.create!(citation_token: "E26", snapshot: { "merchant" => "Source" })

    TransactionAnalysis::Evidence::MAXIMUM_PER_RUN.times do |index|
      target_run.evidences.create!(citation_token: "E#{index + 1}", snapshot: { "merchant" => "Target #{index}" })
    end
    evidence.transaction_analysis_run_id = target_run.id

    assert_raises(ActiveRecord::RecordInvalid) { evidence.save! }
    assert_raises(ActiveRecord::RecordInvalid) { evidence.save!(validate: false) }
    assert_equal TransactionAnalysis::Evidence::MAXIMUM_PER_RUN, target_run.evidences.reload.count
    assert_equal source_run, evidence.reload.run
  end
end
