# frozen_string_literal: true
require 'sinatra'
require 'sqlite3'
require 'json'

# Database Configuration and Connection
DB = SQLite3::Database.new('finance.db').tap do |db|
  # Return query results as key value hash dictionaries instead of positional arrays
  db.results_as_hash = true

  # Enable Write Ahead Logging to permit concurrent database reads while writes occur
  db.execute('PRAGMA journal_mode = WAL;')

  # Transactions table enforcing valid relational integrity constraints at storage layer
  db.execute <<-SQL
    CREATE TABLE IF NOT EXISTS transactions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      category TEXT NOT NULL,
      amount REAL NOT NULL CHECK(amount > 0),
      type TEXT NOT NULL CHECK(type IN ('income', 'expense')),
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );
  SQL

  # Audit logging table storing user inquiries alongside assistant answers
  db.execute <<-SQL
    CREATE TABLE IF NOT EXISTS chat_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      query TEXT NOT NULL,
      reply TEXT NOT NULL,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );
  SQL
end

# Transaction Domain Model Managing Schema Persistence and Aggregations
class Transaction
  # Main parent categories
  CATEGORIES = %w[Food Transport Housing Utilities Entertainment Health Education Personal Salary Freelance Gift General].freeze

  # Simple subcategory map translating user terms to main categories
  SUBCATEGORIES = {
    'coffee' => 'Food',
    'lunch' => 'Food',
    'dinner' => 'Food',
    'groceries' => 'Food',
    'uber' => 'Transport',
    'bus' => 'Transport',
    'train' => 'Transport',
    'fuel' => 'Transport',
    'rent' => 'Housing',
    'wifi' => 'Utilities',
    'power' => 'Utilities',
    'electricity' => 'Utilities',
    'cinema' => 'Entertainment',
    'movie' => 'Entertainment',
    'gym' => 'Health',
    'medicine' => 'Health',
    'books' => 'Education',
    'tuition' => 'Education',
    'clothes' => 'Personal'
  }.freeze

  def self.record(category:, amount:, type:)
    # Normalize input keyword by trimming space and downcasing characters
    key = category.to_s.strip.downcase

    # Match subcategory alias or check main category list falling back to General
    resolved = SUBCATEGORIES[key] || CATEGORIES.find { |c| c.casecmp?(key) } || 'General'

    # Enforce strict float conversion raising an ArgumentError on invalid numeric input
    amt = Float(amount)

    # Validate business invariant preventing zero or negative values
    raise ArgumentError, 'Amount must be greater than zero' if amt <= 0

    # Parameterized query executing insertion without risk of SQL injection
    DB.execute('INSERT INTO transactions (category, amount, type) VALUES (?, ?, ?)', [resolved, amt, type])

    # Return normalized category name and formatted amount
    [resolved, amt]
  end

  def self.totals
    # Aggregate transaction amounts grouped by income and expense types in SQLite
    sql = 'SELECT type, COALESCE(SUM(amount), 0.0) AS total FROM transactions GROUP BY type'

    # Build structured hash using each with object without external accumulator variables
    sums = DB.execute(sql).each_with_object({ 'income' => 0.0, 'expense' => 0.0 }) do |row, acc|
      # Store numeric values keyed by their record classification
      acc[row['type']] = row['total'].to_f
    end

    # Return calculated summary dictionary including remaining balance
    { income: sums['income'], expenses: sums['expense'], balance: sums['income'] - sums['expense'] }
  end

  def self.category_breakdown
    # Group spending totals by category filtered strictly by expense types
    sql = "SELECT category, SUM(amount) AS total FROM transactions WHERE type = 'expense' GROUP BY category"

    # Convert query records into key value dictionary rounded to two decimal places
    DB.execute(sql).to_h { |r| [r['category'], r['total'].to_f.round(2)] }
  end
end