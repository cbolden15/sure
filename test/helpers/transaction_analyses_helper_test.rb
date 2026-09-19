require "test_helper"

class TransactionAnalysesHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "analysis Markdown renders injected links as plain text" do
    rendered = transaction_analysis_markdown(
      "<script>alert('xss')</script> [unsafe](javascript:alert('xss')) [safe](https://sure.finance)"
    )

    assert_no_match(/<script|javascript:|href=/i, rendered)
    assert_includes rendered, "safe"
  end
end
