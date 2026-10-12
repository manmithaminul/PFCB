# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../app'

# Redirect test execution to an isolated test database
TEST_DB = SQLite3::Database.new('test_finance.db').tap do |db|
  db.results_as_hash = true
  db.execute <<-SQL
    CREATE TABLE IF NOT EXISTS transactions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      category TEXT NOT NULL,
      amount REAL NOT NULL CHECK(amount > 0),
      type TEXT NOT NULL CHECK(type IN ('income', 'expense')),
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );
  SQL
  db.execute <<-SQL
    CREATE TABLE IF NOT EXISTS chat_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      query TEXT NOT NULL,
      reply TEXT NOT NULL,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );
  SQL
end

class AppIntegrationTest < Minitest::Test
  def setup
    # Clear only the test database prior to each test case
    TEST_DB.execute('DELETE FROM transactions;')
    TEST_DB.execute('DELETE FROM chat_logs;')
  end

  def test_expense_and_income_flow
    res1 = FinanceEngine.process('income salary 1200')
    assert_includes res1, 'Recorded Income: $1200.00'

    res2 = FinanceEngine.process('expense food 45')
    assert_includes res2, 'Recorded Expense: $45.00'

    totals = Transaction.totals
    assert_operator totals[:income], :>=, 1200.0
    assert_operator totals[:expenses], :>=, 45.0
  end

  def test_budget_rule_calculation
    FinanceEngine.process('income salary 1000')
    summary = FinanceEngine.process('budget')
    assert_includes summary, '50% Needs Limit:'
    assert_includes summary, '20% Savings Target:'
  end

  def test_chat_audit_persistence
    FinanceEngine.process('balance')
    count = DB.get_first_value('SELECT COUNT(*) FROM chat_logs;').to_i
    assert_operator count, :>=, 1
  end
end