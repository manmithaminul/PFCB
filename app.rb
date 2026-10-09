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

# Conversational Domain Service Implementing Simplified Financial Workflow
class FinanceEngine
  # Regex to parse: expense <category> <amount> OR spent <amount> on <category>
  EXPENSE_PAT = /\A(?:2\b|expense)\s+([a-zA-Z]+)\s+\$?(\d+(?:\.\d{1,2})?)\z/i
  NATURAL_EXPENSE_PAT = /(?:spent|bought|paid)\s+\$?(\d+(?:\.\d{1,2})?)\s+(?:on|for)\s+([a-zA-Z]+)/i

  # Regex to parse: income <category> <amount> OR received <amount> as <category>
  INCOME_PAT = /\A(?:1\b|income)\s+([a-zA-Z]+)\s+\$?(\d+(?:\.\d{1,2})?)\z/i
  NATURAL_INCOME_PAT = /(?:received|earned|got)\s+\$?(\d+(?:\.\d{1,2})?)(?:\s+(?:from|for|as)\s+([a-zA-Z]+))?/i

  def self.process(input)
    # Clean input text
    text = input.to_s.strip

    # Return early if user submits blank message
    return 'Please enter a command or type menu.' if text.empty?

    # Pattern match input against the 5 simple core functions
    reply = case text
            when /\A(menu|help|commands|start|hi|hello)\z/i
              "Financial Assistant Menu:\n\n" \
              "Commands:\n" \
              "1. income <category> <amount>  (e.g. income salary 1200)\n" \
              "2. expense <category> <amount> (e.g. expense food 25)\n" \
              "3. balance  (view total earned, spent, and remaining)\n" \
              "4. breakdown  (summary of all expenses and remaining cash)\n" \
              "5. budget  (50/30/20 target analysis and suggested changes)\n\n" \
              "Available Subcategories:\n" \
              "• Food: groceries, coffee, lunch, dinner\n" \
              "• Transport: uber, bus, train, fuel\n" \
              "• Living: rent, wifi, power, electricity\n" \
              "• Lifestyle: cinema, gym, medicine, clothes\n" \
              "• Income: salary, freelance, gift"

            when /\A(1|income)\z/i
              "How to add Income:\n" \
              "Type: income <category> <amount>\n" \
              "Example: income salary 1200\n" \
              "Available Categories: salary, freelance, gift"

            when /\A(2|expense|expenses)\z/i
              "How to add an Expense:\n" \
              "Type: expense <category> <amount>\n" \
              "Example: expense food 25\n" \
              "Subcategories: food (groceries, coffee, lunch), transport (uber, bus, fuel), rent, utilities (wifi, power), entertainment (cinema), health (gym, medicine)"

            when EXPENSE_PAT
              # Direct command format: expense <category> <amount>
              cat, amt = Transaction.record(category: Regexp.last_match(1), amount: Regexp.last_match(2), type: 'expense')
              "Recorded Expense: $#{format('%.2f', amt)} under #{cat}."

            when NATURAL_EXPENSE_PAT
              # Conversational format: spent $X on Y
              cat, amt = Transaction.record(category: Regexp.last_match(2), amount: Regexp.last_match(1), type: 'expense')
              "Recorded Expense: $#{format('%.2f', amt)} under #{cat}."

            when INCOME_PAT
              # Direct command format: income <category> <amount>
              cat, amt = Transaction.record(category: Regexp.last_match(1), amount: Regexp.last_match(2), type: 'income')
              "Recorded Income: $#{format('%.2f', amt)} under #{cat}."

            when NATURAL_INCOME_PAT
              # Conversational format: received $X as Y
              source = Regexp.last_match(2) || 'Salary'
              cat, amt = Transaction.record(category: source, amount: Regexp.last_match(1), type: 'income')
              "Recorded Income: $#{format('%.2f', amt)} under #{cat}."

            when /\A(3|balance|status)\z/i
              # Balance calculation showing income, expenses, and remaining funds
              t = Transaction.totals
              status_note = t[:balance] >= 0 ? 'You have positive savings!' : 'Warning: You are in deficit!'
              "Current Balance:\n" \
              "Total Earned: $#{format('%.2f', t[:income])}\n" \
              "Total Spent:  $#{format('%.2f', t[:expenses])}\n" \
              "Remaining:    $#{format('%.2f', t[:balance])}\n" \
              "#{status_note}"

            when /\A(4|breakdown|summary)\z/i
              # Itemized breakdown of all expenses and remaining cash
              breakdown = Transaction.category_breakdown
              t = Transaction.totals

              if breakdown.empty?
                'No expenses recorded yet. Use: expense <category> <amount>'
              else
                items = breakdown.map { |k, v| "• #{k}: $#{format('%.2f', v)}" }.join("\n")
                "Expense Summary:\n" \
                "#{items}\n" \
                "Total Expenses: $#{format('%.2f', t[:expenses])}\n" \
                "Remaining Cash: $#{format('%.2f', t[:balance])}"
              end

            when /\A(5|budget|changes)\z/i
              # 50 30 20 budget targets and actionable advice on changes to make
              inc = Transaction.totals[:income]
              exp = Transaction.totals[:expenses]

              if inc.zero?
                'Please record your income first (e.g. income salary 1000) to calculate budget targets.'
              else
                needs_target = inc * 0.50
                wants_target = inc * 0.30
                savings_target = inc * 0.20

                # Formulate actionable change recommendation
                advice = if exp > (needs_target + wants_target)
                           'Action to take: You have spent more than 80% of your earnings. Reduce discretionary spending to preserve your 20% savings.'
                         else
                           'Budget health is good: You are within target. Aim to allocate at least 20% into savings.'
                         end

                "Budget Plan (50/30/20 Targets):\n" \
                "• 50% Needs Limit:    $#{format('%.2f', needs_target)}\n" \
                "• 30% Wants Limit:    $#{format('%.2f', wants_target)}\n" \
                "• 20% Savings Target: $#{format('%.2f', savings_target)}\n" \
                "Total Spent So Far:   $#{format('%.2f', exp)}\n\n" \
                "Suggested Changes:\n#{advice}"
              end

              when /\A(reset|clear)\z/i
              DB.execute('DELETE FROM transactions;')
              'All transactions cleared. Starting with a fresh balance.'

            else
              "Command not recognized. Type menu to view the 5 available options."
            end

    # Write interaction to database audit log
    DB.execute('INSERT INTO chat_logs (query, reply) VALUES (?, ?)', [text, reply])

    reply
  rescue StandardError => e
    # Catch runtime exceptions gracefully and display descriptive error message
    "Error: #{e.message}"
  end
end