# coding: utf-8
require 'pp'
require 'sqlite3'
require 'digest'
require 'date'
require 'sinatra'
require 'pry'
require 'csv'
require 'ostruct'
require 'pdfkit'
require 'zip'

require './config.rb'

include ERB::Util

DOC_FOLDER = ENV["DOC_FOLDER"]
THUMB_FOLDER = ENV["THUMB_FOLDER"]
INVOICES_CSV_FOLDER = ENV["INVOICES_CSV_FOLDER"]
EXPORT_FOLDER = ENV["EXPORT_FOLDER"]
PREFIX = ENV["PREFIX"]

TAX_RATES = {
  "NONEU0" => 0,
  "EU19" => 19,
  "EU7" => 7
}

PDFKit.configure do |config|
  config.wkhtmltopdf = "#{Dir.pwd}/wkhtmltopdf.sh"
end

class Book
  attr_accessor :acc_id, :bookings_for_debit_acc, :bookings_for_credit_acc, :book_rows, :bank_rows, :bookings_todo, :bookings_by_txn_id
  attr_accessor :bookings_by_receipt_url, :bookings_by_invoice_id, :document_state_by_path
  attr_accessor :invoice_rows
  
  def initialize
    @acc_id = ENV["BANK_ACC"]
    @paypal_acc_id = ENV["PP_USER"]
    @db_exists = false
    @db_filename = "receipts.db"
    @bank_acc_db_filename = "bank-#{@acc_id}.db"
    @paypal_db_filename = "paypal-#{@paypal_acc_id}.db"
    
    @bookings_for_debit_acc = {}
    @bookings_for_credit_acc = {}
    @book_rows = []
    @bank_rows = []
    @bookings_todo = []
    @bookings_by_txn_id = {}
    @document_state_by_path = {}

    @invoice_rows = []
    
    if File.file?(@db_filename)
      @db_exists = true
    end

    @book_db = SQLite3::Database.new @db_filename
    @book_db.results_as_hash = true

    if !@db_exists
      create_book_db(@book_db)
    end

    @bank_acc_db = SQLite3::Database.new @bank_acc_db_filename
    @paypal_db = SQLite3::Database.new @paypal_db_filename
  end

  def create_book_db(db)
    db.execute <<-SQL
      create table book (
        id varchar(32) not null primary key,
        date varchar(23),
        amount_cents int,
        details text,
        currency varchar(4),
        receipt_url text,
        tax_code varchar(8),
        debit_account varchar(32),
        credit_account varchar(32),
        debit_txn_id varchar(32),
        credit_txn_id varchar(32)
      );
    SQL

    # TODO: unify txn_ids into one
    
    db.execute <<-SQL
      create table invoices (
        invoice_id varchar(64) not null primary key,
        date varchar(23),
        amount_cents int,
        details text,
        currency varchar(4),
        tax_code varchar(8),
        sales_account varchar(32),
        order_id  varchar (32),
        payment_method  varchar (32),
        line_items text,
        customer_account varchar(32),
        customer_company text,
        customer_name  text,
        customer_address_1 text,
        customer_address_2 text,
        customer_zip text,
        customer_city  text,
        customer_state text,
        customer_country text,
        vat_included int
      );
    SQL

    db.execute <<-SQL
      create table documents (
        path varchar(512) not null primary key,
        state varchar(32) not null,
        docid varchar(32),
        date varchar(23),

        sum varchar(32),
        
        tags TEXT
      );
    SQL
    
    db.execute <<-SQL
      create index date_idx on book(date);
    SQL

    puts "Book DB created."
  end

  def create_booking(booking)

    # FIXME hash, no direct indexing!
    
    new_row = ["",booking[:date],booking[:amount_cents],booking[:details],booking[:currency],booking[:receipt_url],booking[:tax_code],booking[:debit_account],booking[:credit_account],booking[:debit_txn_id],booking[:credit_txn_id]]

    id_raw = "#{new_row[1]}#{new_row[2]}#{new_row[7]}#{new_row[8]}#{new_row[9]}#{new_row[10]}"
    id = Digest::MD5.hexdigest(id_raw)
    new_row[0] = id
    
    @book_db.execute("INSERT INTO book (id, date, amount_cents, details, currency, receipt_url, tax_code, debit_account, credit_account, debit_txn_id, credit_txn_id, order_id, invoice_id, invoice_lines, invoice_payment_method, invoice_company, invoice_name, invoice_address_1, invoice_address_2, invoice_zip, invoice_city, invoice_state, invoice_country) 
            VALUES (?, ?, ?, ?, ?,  ?, ?, ?, ?, ?,  ?, ?, ?, ?, ?,  ?, ?, ?, ?, ?,  ?, ?, ?)", new_row)

  end
  
  def create_invoice(invoice)
    new_row = [invoice[:id],invoice[:invoice_date],invoice[:amount_cents],invoice[:details],invoice[:currency],invoice[:tax_code],invoice[:customer_account],invoice[:sales_account],invoice[:order_id],invoice[:line_items],invoice[:payment_method],invoice[:customer_company],invoice[:customer_name],invoice[:customer_address_1],invoice[:customer_address_2],invoice[:customer_zip],invoice[:customer_city],invoice[:customer_state],invoice[:customer_country],invoice[:vat_included]]
    
    @book_db.execute("INSERT INTO invoices (id, invoice_date, amount_cents, details, currency, tax_code, customer_account, sales_account, order_id, line_items, payment_method, customer_company, customer_name, customer_address_1, customer_address_2, customer_zip, customer_city, customer_state, customer_country, vat_included) 
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", new_row)
  end

  def link_receipt(id,receipt_url)
    @book_db.execute("update book set receipt_url = ? where id = ?", receipt_url, id)
  end

  def reload_book
    @bookings_todo = []
    @bookings_by_txn_id = {}
    @bookings_for_debit_acc = {}
    @bookings_for_credit_acc = {}
    @bookings_by_invoice_id = {}
    @bookings_by_receipt_url = {}
    @invoices_by_customer = {}
    @documents = []
    @document_state_by_path = {}
    @document_by_path = {}

    ### load all invoice rows into memory

    @invoice_rows = @book_db.execute <<-SQL
select * from invoices order by id desc;
SQL
    converted_invoice_rows = []
    @invoice_rows.each do |row|
      row = OpenStruct.new(row)
      converted_invoice_rows.push(row)
    end
    @invoice_rows = converted_invoice_rows

    ##############################################################
    ### load all book rows into memory
    
    @book_rows = @book_db.execute <<-SQL
select * from book order by date desc;
SQL

    converted_book_rows = []

    # create hashes for quick lookup by certain fields
    @book_rows.each do |row|
      row = OpenStruct.new(row)
      converted_book_rows.push(row)
      
      if !@bookings_for_debit_acc[row[:debit_account]]
        @bookings_for_debit_acc[row[:debit_account]]={}
      end
      if !@bookings_for_credit_acc[row[:credit_account]]
        @bookings_for_credit_acc[row[:credit_account]]={}
      end
      @bookings_for_debit_acc[row[:debit_account]][row[:debit_txn_id]]=row
      @bookings_for_credit_acc[row[:credit_account]][row[:credit_txn_id]]=row

      receipt_urls = []
      receipt_urls = row[:receipt_url].split(",") unless row[:receipt_url].nil?
      invoice_id = row[:invoice_id]

      receipt_urls.each do |receipt_url|
        if !@bookings_by_receipt_url[receipt_url]
          @bookings_by_receipt_url[receipt_url]=[]
        end
        @bookings_by_receipt_url[receipt_url].push(row)
      end
      
      if !@bookings_by_invoice_id[invoice_id]
        @bookings_by_invoice_id[invoice_id]=[]
      end
      if !invoice_id.nil? && invoice_id.size>0
        @bookings_by_invoice_id[invoice_id].push(row)
      end
    end
    @book_rows = converted_book_rows

    reload_documents

    ##############################################################
    #
    # bank, paypal rows import
    #
    # TODO factor out into modules
    # TODO create some kind of rule system for this
    #
    # if a bank_reference is set, this is a "not-yet-booked" transaction for which
    # a duplicate "real" transaction appears later
    #
    @bank_rows = @bank_acc_db.execute <<-SQL
      select id,date,amount_cents,details,transaction_code,"EUR" from transactions where length(bank_reference)=0 order by date desc;
    SQL

    acc_key = "assets:bank-#{acc_id}"
    if !@bookings_for_debit_acc[acc_key]
      @bookings_for_debit_acc[acc_key]={}
    end
    if !@bookings_for_credit_acc[acc_key]
      @bookings_for_credit_acc[acc_key]={}
    end

    @bank_rows.each do |row|
      amount = row[2]
      txn_code = row[4].to_i
      details = row[3]
      det = details.gsub(" ","")
      date = row[1]

      id = row[0]
      curyear = Date.today.year
      lastyear = curyear-1

      new_booking = {
        :date => date,
        :amount_cents => amount,
        :details => details,
        :currency => "EUR",
        :tax_code => ""
      }

      if amount<0
        # negative amounts are debited from the account
        if !bookings_for_debit_acc[acc_key][id]
          # we paid money
          # there is no booking / receipt. can we create one automatically?

          new_booking[:amount_cents] = -amount # only positive amounts are transferred
          new_booking[:debit_account] = acc_key
          new_booking[:debit_txn_id] = row[0]
          
          @bookings_todo.push(row)
          @bookings_by_txn_id[id] = new_booking
        end
      else
        # we got some money.
        if !bookings_for_credit_acc[acc_key][id]
          
          new_booking[:credit_account] = acc_key
          new_booking[:credit_txn_id] = row[0]
          
          @bookings_todo.push(row)
          @bookings_by_txn_id[id] = new_booking
        end
      end
    end

    # PAYPAL IMPORT
    @paypal_rows = @paypal_db.execute <<-SQL
      select id,date,amount_cents,amount_fee_cents,email,name,currency,txn_type,status from transactions order by date desc;
    SQL

    acc_key = "assets:paypal"  # TODO multiple accounts
    if !@bookings_for_debit_acc[acc_key]
      @bookings_for_debit_acc[acc_key]={}
    end
    if !@bookings_for_credit_acc[acc_key]
      @bookings_for_credit_acc[acc_key]={}
    end
    
    @paypal_rows.each do |row|
      id = row[0]
      date = row[1]
      amount = row[2]
      currency = row[6]
      txn_type = row[7]
      status = row[8]
      email = row[4]
      name = row[5]
      details = "PP #{status} #{txn_type} #{email} #{name}"
      
      new_booking = {
        :date => date,
        :amount_cents => amount,
        :details => details,
        :currency => currency,
        :tax_code => ""
      }

      bank_row = [
        id,
        date,
        amount,
        details,
        id,
        currency
      ]

      # FIXME create 2nd bookings for fees
      if txn_type=="Transfer" || txn_type=="Authorization"
        # TODO: update matching bank transfer with txn id
      elsif status!="Completed" && status!="Refunded"
        # TODO: not sure what to do with pending txns... maybe display somewhere else
      elsif txn_type.match(/Currency Conversion/) || txn_type.match(/Fee Reversal/)
        # TODO: later we can book these to currency exchange accounts?
      else
        if amount<0
          # negative amounts are debited from the account
          if !bookings_for_debit_acc[acc_key][id]
            # we paid money
            # there is no booking / receipt. can we create one automatically?

            new_booking[:amount] = -amount # only positive amounts are transferred
            new_booking[:debit_account] = acc_key
            new_booking[:debit_txn_id] = id

            bank_row[2] = -amount
            
            @bookings_todo.push(bank_row)
            @bookings_by_txn_id[id] = new_booking
          end
        else
          # we got some money.
          if !bookings_for_credit_acc[acc_key][id]
            
            new_booking[:credit_account] = acc_key
            new_booking[:credit_txn_id] = id
            
            @bookings_todo.push(bank_row)
            @bookings_by_txn_id[id] = new_booking
          end
        end
      end
    end
  end

  def reload_documents
    ##############################################################
    ### load all document rows into memory
    
    @doc_rows = @book_db.execute <<-SQL
select path,state,docid,date,sum,tags from documents order by date;
SQL

    @doc_rows.each do |doc|
      doc = OpenStruct.new(doc)
      @document_state_by_path[doc[:path]]=doc[:state]
      @document_by_path[doc[:path]]=doc
      @documents.push(doc)
    end
  end

  def get_invoice(id)
    results = @book_db.execute("select * from invoices where id=?", id)
    OpenStruct.new(results.first)
  end

  def get_document_state(pdfname)
    (@document_by_path[pdfname] || {:state => "unfiled"})[:state]
  end

  def get_document_metadata(pdfname)
    @document_by_path[pdfname] || {}
  end

  def get_all_documents()
    @documents
  end

  def all_invoices()
    @documents.select {|d| d[:doctype]=="invoice"}
  end

  def update_document_state(pdfname, state)
    if get_document_state(pdfname) == "unfiled"
      @book_db.execute("replace into documents (path,state) values (?,?)",[pdfname, state])
    else
      @book_db.execute("update documents set state=? where path=?",[state, pdfname])
    end
    reload_documents
  end
  
  def update_document_metadata(pdfname, docid, date, sum, tags)
    puts "update metadata:",[docid,date,sum,tags,pdfname]
    @book_db.execute("update documents set docid=?,date=?,sum=?,tags=? where path=?",[docid,date,sum,tags,pdfname])
  end

  def debit_accounts
    @book_db.execute("select distinct(debit_account) from book").map(&:first).flatten.reject(&:nil?)
  end
  
  def credit_accounts
    @book_db.execute("select distinct(credit_account) from book").map(&:first).flatten.reject(&:nil?)
  end
  
  def customer_accounts
    (debit_accounts+credit_accounts).select {|a|a.match(/^customer/)}.sort.uniq
  end

  # FIXME some filenames can contain ",", sanitize!
  
  def export_quarter
    quarters = {}
    
    rows = @book_db.execute <<-SQL
select id,debit_account,credit_account,date,amount_cents,receipt_url,invoice_id,currency from book order by date desc;
SQL

    rows.each do |row|
      row = OpenStruct.new(row)
      receipt = row[:receipt_url]
      if row[:debit_account].nil?
        #puts "Warning: no debit_account"
      elsif row[:credit_account].nil?
        #puts "Warning: no credit_account"
      elsif receipt.nil? || !receipt || receipt == "none"
        #puts "Warning: no receipt"
      elsif row[:debit_account]=="external"
      elsif row[:credit_account].match(/^customer:/)
      else
        receipt = receipt.split('#')[0]
        date = row[:date][0..9]
        debit = row[:debit_account].gsub(":","-")
        credit = row[:credit_account].gsub(":","-")
        amount = row[:amount_cents]/100
        currency = row[:currency]

        mon = date[5..6].to_i
        quarter = (mon-1)/3+1
        subdir = "#{date[0..3]}Q#{quarter}"
        quarters[subdir] = true

        Dir.mkdir(EXPORT_FOLDER) unless File.exists?("export")
        Dir.mkdir("#{EXPORT_FOLDER}/#{subdir}") unless File.exists?("export/#{subdir}")

        subdir_category = "incoming-invoices-non-resale"
        if credit.match /(parts|packaging|shipping)/
          subdir_category = "incoming-invoices-resale"
        elsif credit.match /sales/
          subdir_category = "outgoing-invoices"
        end
        
        dirname = "#{EXPORT_FOLDER}/#{subdir}/#{subdir_category}"
        Dir.mkdir(dirname) unless File.exists?(dirname)
        
        receipt.split(",").each do |r|
          unless receipt[0]=="/"
            fname = "#{dirname}/#{date}-#{amount}#{currency}-#{r}"
            #puts "#{fname} <- #{r}"
            src = DOC_FOLDER+"/"+r
            FileUtils.cp(src,fname)
          end
        end
      end
    end

    # FIXME these should also be booked as cash transactions
    # FIXME extract documents that have a sum but no associated booking
    
    rows = @book_db.execute <<-SQL
select path,state,docid,date,sum,tags from documents order by date desc;
SQL
    rows.each do |row|
      row = OpenStruct.new(row)

      if !row[:tags].nil?
        tags = row[:tags].split(",").sort
        if tags.include?("cash")
          date = row[:date][0..9]
          amount = row[:sum]
          currency = "EUR" # FIXME
          
          mon = date[5..6].to_i
          quarter = (mon-1)/3+1
          subdir = "#{date[0..3]}Q#{quarter}"
          quarters[subdir] = true

          Dir.mkdir(EXPORT_FOLDER) unless File.exists?("export")
          Dir.mkdir("#{EXPORT_FOLDER}/#{subdir}") unless File.exists?("export/#{subdir}")

          subdir_category = "incoming-invoices-cash-non-resale"
          dirname = "#{EXPORT_FOLDER}/#{subdir}/#{subdir_category}"
          Dir.mkdir(dirname) unless File.exists?(dirname)
          
          fname = "#{dirname}/#{date}-#{amount}#{currency}-#{tags.join('-')}.pdf"
          puts "#{fname} <- #{row[:path]}"
          src = DOC_FOLDER+"/"+row[:path]
          FileUtils.cp(src,fname)
        end
      end
    end

    quarters.keys
  end
end

def clean_bank_row_description(raw_desc)

  if raw_desc[0..1]=="PP"
    return {
      :details => raw_desc,
      :fields => [],
      :iban => nil
    }
  end
  
  iban_rx = /[A-Z0-9]+ [A-Z]{2}[0-9]{2}[A-Z0-9]{8,}/

  fields = raw_desc.scan(/([A-Z]{4}[\+\-][^ ]+)/)
  desc = "SVWZ+"+((raw_desc.split("SVWZ+").last).split(/([A-Z]{4}[\+\-])/).first)

  # heuristic to fix text with bogus spaces inserted
  fixed_desc = ""
  iban = ""
  if desc.size>27 && desc[27]==" "
    # remove space in first field
    desc = desc[0..26]+desc[28..-1]
  elsif desc.size>26 && desc[26]==" "
    # sometimes the first field can be 1 char shorter
    desc = desc[0..25]+desc[27..-1]
  end

  # match an iban and after that, remove another spacer
  iban_match = desc.match(iban_rx)
  if iban_match
    iban = iban_match[0]
    idx = desc.index(iban_rx)
    idx_split = idx+iban.size+27

    if (desc.size>=idx_split+2)
      desc = desc[0..idx_split]+desc[idx_split+2..-1]
    else
      desc = desc[0..idx_split]
    end

    desc1 = desc[0..idx-1].gsub("SVWZ+","")
    desc2 = desc[idx+iban.size+1..-1]
  end

  desc.gsub!("SVWZ+","")
  
  return {
    :details => desc,
    :details_line_1 => desc1,
    :details_line_2 => desc2,
    :fields => fields,
    :iban => iban
  }
end

# id,date,amount_cents,details,transaction_code,currency
def bank_row_to_hash(b)
  desc = clean_bank_row_description(b[3])
  
  return {
    :id => b[0], # FIXME named indexes
    :date => b[1][0..9],
    :amount_cents => b[2],
    :currency => b[5],
    :details => desc[:details],
    :details_line_1 => desc[:details_line_1]||desc[:details],
    :details_line_2 => desc[:details_line_2],
    :fields => desc[:fields],
    :iban => desc[:iban]
  }
end

def make_receipt_urls(raw_receipt_url)
  receipt_urls = []
  if raw_receipt_url
    receipt_urls_raw = raw_receipt_url.split(",")
    receipt_urls_raw.each do |r|
      if r=="none"
        r=""
      elsif r[0]!="/"
        r = "#{PREFIX}/pdf/#{r}"
      end
      receipt_urls.push(r)
    end
  end
  receipt_urls
end

# select id,debit_account,debit_txn_id,credit_account,credit_txn_id,date,amount,details,receipt_url,currency from book;
def book_row_to_hash(b)  
  klass = ""
  #if !b[:credit_account].nil? && b[:credit_account].match("assets:bank-")
  #  klass = "credit-bank"
  #end

  receipt_urls = make_receipt_urls(b[:receipt_url])
  desc = clean_bank_row_description(b[:details])

  return {
    :id => b[:id],
    :date => b[:date][0..9],
    :currency => b[:currency], #.sub("EUR","€"),
    :amount_cents => b[:amount_cents],
    :debit_account => b[:debit_account],
    :credit_account => b[:credit_account],
    :details => desc[:details],
    :details_line_1 => desc[:details_line_1]||desc[:details],
    :details_line_2 => desc[:details_line_2],
    :receipt_urls => receipt_urls,
    :css_class => klass
  }
end

# FIXME why here?
book = Book.new

# actually move this to book class

def fetch_all_documents(book)
  docs = []
  
  paths = Dir.glob(DOC_FOLDER+"/**.pdf").sort
  paths.each do |path|
    basename = File.basename(path,".pdf")
    thumbname = "#{basename}.png"
    textname = "#{basename}.txt"
    pdfname = "#{basename}.pdf"
    thumbpath = THUMB_FOLDER+"/"+thumbname
    textpath = THUMB_FOLDER+"/"+textname

    #puts "~~ PDF: #{path} ~~"
    
    # TODO: move this to the background / ocr cron
    
    if !File.exist?(thumbpath) then
      puts "    '-- creating thumbnail"
      gs_cmd="gs -sDEVICE=pngalpha -dGraphicsAlphaBits=4 -dTextAlphaBits=4 -dDOINTERPOLATE -sOutputFile=\"#{thumbpath}\" -dSAFER -dBATCH -dNOPAUSE -r120% \"#{path}\""
      puts "GS|#{gs_cmd}"
      puts `#{gs_cmd}`
      puts `mogrify -resize 900 "#{thumbpath}"`
    end
    
    if !File.exist?(textpath) then
      puts "    '-- creating text extract"
      puts `pdftotext "#{path}" "#{textpath}"`
    end

    if File.exist?(textpath) then
      text = File.read(textpath)
    else
      text = "Text not available (password protected PDF?)"
    end

    state = "unfiled"
    booking_ids = []
    if book.bookings_by_receipt_url[pdfname]
      state = "booked"
      booking_ids = book.bookings_by_receipt_url[pdfname].map {|b| b[:id]}
    else
      state = book.get_document_state(pdfname)
    end

    # FIXME why are these 2 linked structures instead of one?
    
    metadata = book.get_document_metadata(pdfname)
    
    docs.push({
                path: path,
                title: pdfname,
                thumbnail: PREFIX+"/thumbnails/#{thumbname}",
                created: File.mtime(path),
                text: text,
                state: state,
                metadata: metadata,
                id: Digest::MD5.hexdigest(path),
                booking_ids: booking_ids
              })
  end

  docs
end

def validate_state(new_state)
  if new_state.match(/^(todo|archive|defer|unfiled|booked)$/)
    new_state
  else
    false
  end
end

def render_document_list(book, params, notification)
  book.reload_book
  docs = fetch_all_documents(book)

  state = params["state"]

  if validate_state(params["state"])
    docs = docs.select do |d|
      d[:state] == params["state"]
    end
  end
  
  erb :documents, :locals => {
        :docs => docs,
	      :prefix => PREFIX,
        :active => "docs_#{state}".to_sym,
        :state => state,
        :notification => notification
      }
end

get PREFIX+'/documents' do
  render_document_list(book, params, nil)
end

post PREFIX+'/documents' do
  book.reload_book
  docs = fetch_all_documents(book)

  if !File.exists?("rotate-bak")
    Dir.mkdir("rotate-bak")
  end

  target_state = validate_state(params["state"])||"unfiled"
  target_docid = ""

  notifications = []

  docs.each do |doc|
    doc = OpenStruct.new(doc)
    new_state = params["doc-#{doc[:id]}-state"]
    name = doc[:title]
    
    if new_state && validate_state(new_state)
      new_state.downcase!
      book.update_document_state(name, new_state)
    end

    new_docid = params["doc-#{doc[:id]}-docid"]
    new_tags =  params["doc-#{doc[:id]}-tags"]
    new_date =  params["doc-#{doc[:id]}-date"]
    new_sum =   params["doc-#{doc[:id]}-sum"]

    if params["doc-#{doc[:id]}-metadata"]
      book.update_document_metadata(name,new_docid,new_date,new_sum,new_tags)
      target_docid=doc[:id]

      notifications.push("#{new_docid} saved to #{new_state}.")
    end
  end

  notification = nil
  if notifications.size > 0
    notification = notifications.join(" ")
  end
  
  render_document_list(book, params, notification)
end

get PREFIX+'/invoices' do
  # display a table of all bookings with valid invoice_id
  book.reload_book

  months={}
  
  invoices=book.invoice_rows
  
  invoices=invoices.map do |i|
    i[:receipt_urls] = []
    i[:receipt_urls].push(PREFIX+"/invoices/#{i.id}")
    i[:receipt_urls].push(PREFIX+"/invoices/#{i.id}?pdf=1")

    date = Date.parse(i[:invoice_date])
    month_key = "#{date.year}-#{date.month}"
    if !months[month_key]
      months[month_key]={
        :invoices => [],
        :sum_cents => 0
      }
    end
    months[month_key][:invoices].push(i)
    months[month_key][:sum_cents]+=i[:amount_cents]

    # FIXME was the invoice paid? look for a matching crediting transaction
    i[:paid] = false
    i[:payments] = []
    i
  end
    
  erb :invoices, :locals => {
        :months => months,
	      :prefix => PREFIX
      }
end

get PREFIX+'/invoices/new' do
  # new invoice form

  book.reload_book
  customers=book.customer_accounts

  # create a map of customer accounts to most recent address
  
  addresses = {}
  customers.each do |c|
    bs = book.bookings_for_debit_acc[c]
    if !bs.nil?
      b = bs.values.last
      addresses[c] = {
        :company => b[:invoice_company],
        :name => b[:invoice_name],
        :addr1 => b[:invoice_address_1],
        :addr2 => b[:invoice_address_2],
        :city => b[:invoice_city],
        :zip => b[:invoice_zip],
        :state => b[:invoice_state],
        :country => b[:invoice_country]
      }
    end
  end
  
  erb :new_invoice, :locals => {
        :customers => customers,
        :addresses => addresses,
        :prefix => PREFIX,
        :invoice_date => Date.today
      }
end

def company_details_for_date(date)
  COMPANY_DETAILS.each do |det|
    if date >= det[:since]
      return det
    end
  end
  nil
end

def create_invoice_pdf(html, invoice)
  kit = PDFKit.new(html, :page_size => 'A4')
  pdf_path = "#{DOC_FOLDER}/invoice-#{invoice[:order_id]}-#{invoice[:id]}.pdf"
  file = kit.to_file(pdf_path)
  file
end

def render_invoice_html(invoice)
  if invoice[:line_items][0] == '['
    invoice[:line_items] = JSON.parse(invoice[:line_items])
  else
    # legacy format
    # FIXME move this to invoice importer
    ils = []
    ils_raw = invoice[:line_items].split("$")
    ils_raw.each do |il|
      il_raw = il.split("|")
      ils.push({
        "title" => il_raw[0],
        "quantity" => il_raw[1],
        "price_cents" => il_raw[2].to_f*100.0,
        "description" => il_raw[3],
        "amount_cents" => il_raw[1].to_f*il_raw[2].to_f*100.0,
        "sku" => ""
      })
    end
    invoice[:line_items] = ils
  end

  total = invoice[:amount_cents]/100.0
  tax_rate = TAX_RATES[invoice[:tax_code]] || 0
  invoice[:tax_rate] = tax_rate
  net_total = (total/(1.0+tax_rate/100.0))
  invoice[:tax_total] = '%.2f' % (net_total*tax_rate/100.0)
  invoice[:net_total] = '%.2f' % net_total
  invoice[:total] = '%.2f' % total

  # FIXME take these strings from config/locale
  outro = ""
  if tax_rate == 0
    outro = "Steuerfreie Ausfuhrlieferungen nach § 4 Nr. 1a UStG in Verbindung mit § 6 UStG."
  end
  terms = "Bitte begleichen Sie die Rechnung innerhalb von 7 Tagen ab Rechnungsdatum."
  if invoice[:payment_method].match(/paypal/i)
    terms = "Die Rechnung wurde bereits per PayPal beglichen."
  elsif invoice[:payment_method].match(/cash/i)
    terms = "Die Rechnung wurde bereits bar beglichen."
  end

  company = company_details_for_date(Date.parse(invoice[:invoice_date]))
  
  html = erb :invoice, :locals => {
               :invoice => invoice,
               :sender_address_lines => company[:address],
               :sender_bank_lines => company[:bank],
               :sender_legal_lines => company[:legal],
               :terms => terms,
               :outro => outro,
	             :prefix => PREFIX
             }

  html
end

get PREFIX+'/invoices/:id' do
  # display/render an invoice

  invoice_id = params["id"]
  book.reload_book
  invoice = book.get_invoice(invoice_id)
  html = render_invoice_html(invoice)
  
  if params["pdf"]
    content_type 'application/pdf'
    create_invoice_pdf(html, invoice)
  else
    html
  end
  
end

post PREFIX+'/invoices' do
  # create a new invoice by posting JSON data
  # or update existing invoice depending on ID
  # TODO input validation

  content_type 'application/json'
  book.reload_book
  
  request.body.rewind
  payload = JSON.parse(request.body.read)

  # automatic invoice ID
  # find all invoice ids from this year and increment by 1
  year = Date.today.year
  
  invoices=book.invoice_rows.select do |b|
    if !b[:id].nil?
      b[:id].match(/^#{year}/)
    else
      false
    end
  end
  invoice_ids=invoices.map do |i|
    i[:id].split("-").last.to_i
  end
  invoice_ids.push(0)
  iid = invoice_ids.sort.last+1
  formatted_iid = "#{year}-#{iid.to_s.rjust(4,'0')}"

  # override automatic ID by given invoice ID
  if payload["iid"].to_s.size>4
    formatted_iid = payload["iid"]
  end

  payload["id"] = formatted_iid
  payload["details"] = "Invoice #{formatted_iid}"
  payload["vat_included"] = payload["vat_included"].to_s

  payload = OpenStruct.new(payload)
  
  book.create_invoice(payload)

  # create PDF invoice
  book.reload_book
  invoice = book.get_invoice(formatted_iid)
  html = render_invoice_html(invoice)
  create_invoice_pdf(html, invoice)
  
  payload.to_h.to_json
end

get PREFIX+'/todo' do
  book.reload_book
  
  rows = book.bookings_todo.map(&method(:bank_row_to_hash))

  debit_accounts = book.debit_accounts
  credit_accounts = book.credit_accounts
  
  default_accounts = ["furniture","tools","consumables","packaging","computers","monitors","computers:input","computers:network","machines","parts:other","parts:reform","parts:va2000","parts:zz9000","sales:reform","sales:va2000","sales:zz9000","sales:services","sales:other","services:legal:taxadvisor","services:legal:notary","services:legal:ip","services:legal:lawyer","taxes:ust","taxes:gwst","taxes:kst","taxes:other","banking","shares","services:design","services:other","shipping","literature","capital-reserve"]
  
  accounts = (debit_accounts+credit_accounts+default_accounts).sort.uniq
  documents = book.get_all_documents.map(&:to_h).select do |d|
    d[:state]!="archive"
  end
  
  invoices = book.invoice_rows

  # FIXME: kludge
  invoices=invoices.map do |i|
    {
      :path => "/invoices/#{i[:id]}",
      :docid => "#{i[:id]}",
      :sum => i[:amount_cents]/100,
      :tags => "invoice,#{i[:customer_account]}"
    }
  end
  
  erb :todo, :locals => {
        :bookings => rows,
        :documents => [documents,invoices].flatten,
        :accounts => accounts,
	      :prefix => PREFIX
      }
end

get PREFIX+'/' do
  redirect PREFIX+"/book"
end

get PREFIX+'/book' do
  book.reload_book

  months={}
  bookings=book.book_rows.map(&method(:book_row_to_hash))

  bookings=bookings.map do |b|
    date = Date.parse(b[:date])
    month_key = "#{date.year}-#{date.month}"
    if !months[month_key]
      months[month_key]={
        :bookings => [],
        :sum_cents => 0
      }
    end
    months[month_key][:bookings].push(b)

    # pseudo summing
    if b[:currency]=="EUR" # FIXME kludge
      if b[:debit_account].to_s.match("assets:") && !b[:credit_account].to_s.match("assets:")
        months[month_key][:sum_cents]-=b[:amount_cents]
      elsif !b[:debit_account].to_s.match("assets:") && (b[:credit_account].to_s.match("assets:"))
        months[month_key][:sum_cents]+=b[:amount_cents]
      end
    end
    
    b
  end
  
  erb :book, :locals => {
        :months => months,
	      :prefix => PREFIX
      }
end

get PREFIX+'/ledger' do
  content_type 'text/plain;charset=utf8'
  book.reload_book

  out = ""
  book.book_rows.reverse.map do |r|
    h = book_row_to_hash(r)
    out+="#{h[:date]} * Transaction\n"
    if h[:amount_cents]<0
      out+="\t#{h[:debit_account]||"unknown"}\t\t#{h[:currency]} #{-h[:amount_cents]/100.0}\n"
      out+="\t#{h[:credit_account]||"unknown"}\n\n"
    else
      out+="\t#{h[:credit_account]||"unknown"}\t\t#{h[:currency]} #{h[:amount_cents]/100.0}\n"
      out+="\t#{h[:debit_account]||"unknown"}\n\n"
    end
  end

  return out
end

get PREFIX+'/export' do
  quarters = book.export_quarter
  erb :export, :locals => {
        :quarters => quarters,
        :prefix => PREFIX
      }
end

# FIXME all of the following need sanitization

get PREFIX+'/export/:name' do
  path = File.join(EXPORT_FOLDER, params[:name])
  
  path.sub!(%r[/$],'')
  archive = File.join(path,File.basename(path))+'.zip'
  FileUtils.rm archive, :force=>true

  Zip::File.open(archive, Zip::File::CREATE) do |zipfile|
    Dir["#{path}/**/**"].reject{|f|f==archive}.each do |file|
      zipfile.add(file.sub(path+'/',''),file)
    end
  end
  
  send_file(archive)
end

get PREFIX+'/pdf/:name' do
  file = File.join(DOC_FOLDER, params[:name])
  send_file(file)
end

get PREFIX+'/thumbnails/:name' do
  file = File.join(THUMB_FOLDER, params[:name])
  send_file(file)
end

get PREFIX+'/dist/:name' do
  file = File.join("dist", params[:name])
  send_file(file)
end

post PREFIX+'/todo' do
  book.reload_book
  
  params.each do |k,v|
    if (id=k.match(/booking-([^\-]+)-receipt/))
      if v && v!="" && v!="null"
        id=id[1]
        
        account = params["booking-#{id}-account"]
        if account && account!="" && account!="null"
          puts "Link #{v} -> #{id}"

          new_booking = book.bookings_by_txn_id[id]
          if !new_booking.nil?
            new_booking[:receipt_url] = v
            if (new_booking[:debit_account]) then
              new_booking[:credit_account] = account
            else
              new_booking[:debit_account] = account
            end
            pp "New booking: ",new_booking
            
            book.create_booking(new_booking)
          else
            puts "ERROR: no booking available for txn #{id}"
          end
        end
      end
    end
  end
  redirect PREFIX+"/todo"
end
