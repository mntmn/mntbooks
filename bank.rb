# coding: utf-8
#
# Import FinTS bank account transactions into transactions table
#

require 'ruby_fints'
require 'pp'
require 'sqlite3'
require 'digest'
require 'date'

acc_id = ENV["BANK_ACC"]
pin = ENV["BANK_PIN"]
bank_code = ENV["BANK_CODE"]
fints_url = ENV["BANK_FINTS_URL"]

db_exists = false
db_filename = "bank-#{acc_id}.db"

if File.file?(db_filename)
  db_exists = true
end

db = SQLite3::Database.new db_filename

def create_account_db(db,acc_id)
  db.execute <<-SQL
  create table transactions (
    id varchar(32) not null primary key,
    date varchar(23),
    amount_cents int,
    details varchar(300),
    entry_date varchar(23),
    storno_flag varchar(4),
    funds_code varchar(4),
    currency_letter varchar(4),
    swift_code varchar(10),
    reference varchar(16),
    bank_reference varchar(16),
    transaction_code varchar(10),
    seperator varchar(4),
    source varchar(30)
  );
  SQL
  
  db.execute <<-SQL
  create index date_idx on transactions(date);
  SQL

  puts "Account DB created."
end

if !db_exists
  create_account_db(db,acc_id)
end

FinTS::Client.logger.level = Logger::DEBUG
f = FinTS::PinTanClient.new(
    bank_code,
    acc_id,
    pin,
    fints_url
)

accounts = f.get_sepa_accounts

statement = f.get_statement(accounts[0], (Date.today - 14), Date.today)

statement.each do |row|
  puts "ROW: ----------------------------------------------"
  pp row.data

  if row.data && row.data["date"]
    parsed_date = Date.new(2000+(row.data["date"][0..1].to_i), row.data["date"][2..3].to_i, row.data["date"][4..5].to_i)
    amount_cents = row.data["amount"].gsub(",","").to_i
    parsed_details = row.details.data["details"].gsub(/\?[0-9]?[0-9]?/," ")
    formatted_date = parsed_date.strftime("%Y-%m-%d 00:00:00.000")

    id = Digest::MD5.hexdigest("#{row.data["date"]}#{amount_cents}#{parsed_details}")
    
    # transaction codes:
    # 835 bank gebühren or auslandszahlung
    # 116 manuelle überweisung
    # 105 abbuchung
    # 166 geld erhalten / einzahlung
    # storno_flag "R" == rückbuchung

    txc = row.details.data["transaction_code"].to_i
    fc = row.data["funds_code"]
    sf = row.data["storno_flag"]
    
    if (fc=="D" && sf!="R") || (fc=="C" && sf=="R")
      # money was moved out of account
      amount_cents = -amount_cents
    end
    
    new_row = [
      id,
      formatted_date,
      amount_cents,
      parsed_details,
      row.data["entry_date"],
      row.data["storno_flag"],
      row.data["funds_code"],
      row.data["currency_letter"],
      row.data["swift_code"],
      row.data["reference"],
      row.data["bank_reference"],
      row.details.data["transaction_code"],
      row.details.data["seperator"],
      row.source
    ]

    pp new_row
    
    db.execute("REPLACE INTO transactions (id, date, amount_cents, details, entry_date, storno_flag, funds_code, currency_letter, swift_code, reference, bank_reference, transaction_code, seperator, source) 
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", new_row)
  end
end
