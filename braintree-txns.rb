require 'rubygems'
require 'braintree'
require 'dotenv/load'
require 'terminal-table'
require 'date'

gateway = Braintree::Gateway.new(
  :environment => :production,
  :merchant_id => ENV["BRAINTREE_MERCHANT_ID"],
  :public_key => ENV["BRAINTREE_PUBLIC_KEY"],
  :private_key => ENV["BRAINTREE_PRIVATE_KEY"],
)

collection = gateway.transaction.search do |search|
  search.payment_instrument_type.is("credit_card")
  search.created_at.between("#{Date.today.year}-01-01 00:00", "#{Date.today.year}-12-31 23:59")
end

rows = []

collection.each do |txn|
  rows << [txn.created_at, "%.2f" % txn.amount, txn.payment_instrument_type, txn.order_id]
end

puts Terminal::Table.new :rows => rows

