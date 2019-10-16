# coding: utf-8
#
# Import Transactions from PayPal to transactions table
#

require "paypal_nvp"
require 'sqlite3'
require 'pp'

acc_id = ENV["PP_USER"]

if (ARGV[0] && ARGV[0].size!=10)
  puts "Usage: ruby paypal.rb <start date, i.e. 2018-06-01> <end date>"
  puts "And set PP_USER, PP_PASS, PP_CERT."
  exit
end

start_date = Date.today-14
if ARGV[0]
  start_date = ARGV[0]+"T00:00:00.000Z"
else
  start_date = "#{start_date}T00:00:00.000Z"
end

end_date = ""
if ARGV[1]
  end_date = ARGV[1]+"T23:59:59.000Z"
end

puts "start_date: #{start_date} end_date: #{end_date}"

db_exists = false
db_filename = "paypal-#{acc_id}.db"

if File.file?(db_filename)
  db_exists = true
end

db = SQLite3::Database.new db_filename

def create_db(db,acc_id)
  db.execute <<-SQL
  create table transactions (
    id varchar(32) not null primary key,
    date varchar(23),
    amount_cents int,
    amount_fee_cents int,
    amount_net_cents int,
    email varchar(300),
    name varchar(300),
    currency varchar(4),
    txn_type varchar(32),
    status varchar(32)
  );
  SQL
  
  db.execute <<-SQL
  create index date_idx on transactions(date);
  SQL

  puts "Txn DB created."
end

if !db_exists
  create_db(db,acc_id)
end

# Or you can specify paramaters directly
# true means "use sandbox"
p = PaypalNVP.new(false, {
  :user => acc_id,
  :pass => ENV["PP_PASS"],
  :cert => ENV["PP_CERT"],
  :url => "https://api-3t.paypal.com/nvp",
  :open_timeout => 3,
  :read_timeout => 60
})

data = {
  #:version => "50.0", # Default is 50.0 as well... but now you can specify it
  :method => "TransactionSearch",
  :StartDate => start_date
}

if end_date!=""
  data[:EndDate] = end_date
end

result = p.call_paypal(data) # will return a hash
#puts result["ACK"] # Success

maxnum = -1

keys = result.keys.select do |k|
  puts "key|#{k}|"
  if k.match(/L_TRANSACTIONID/)
    num = k["L_TRANSACTIONID".size..-1].to_i
    maxnum = num if num>maxnum
  end
end

puts "Got #{maxnum+1} transactions."

rows = []

if maxnum>-1
  (0..maxnum).to_a.each do |n|
    puts "x1|#{n}"
    
    row = [
      result["L_TRANSACTIONID#{n}"],
      result["L_TIMESTAMP#{n}"],
      result["L_TYPE#{n}"],
      (result["L_AMT#{n}"].to_f*100).to_i,
      (result["L_NETAMT#{n}"].to_f*100).to_i,
      (result["L_FEEAMT#{n}"].to_f*100).to_i,
      result["L_EMAIL#{n}"],
      result["L_NAME#{n}"],
      result["L_STATUS#{n}"],
      result["L_CURRENCYCODE#{n}"]
    ]
    rows.push(row)
    
    pp row
    
    db.execute("REPLACE INTO transactions (id, date, txn_type, amount_cents, amount_net_cents, amount_fee_cents, email, name, status, currency) 
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", row)
  end
end

puts "Paypal import done."
