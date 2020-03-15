# coding: utf-8
require 'pp'
require 'sqlite3'
require 'digest'
require 'date'
require 'csv'
require 'ostruct'
require 'pdfkit'
require 'zip'
require 'erb'
require 'uri'

require './config.rb'

PDFKit.configure do |config|
  config.wkhtmltopdf = "#{Dir.pwd}/wkhtmltopdf.sh"
end

def current_iso_date_time
  Time.now.strftime('%Y-%m-%dT%H:%M:%S.%L%z')
end

class Book
  attr_accessor :acc_id, :bookings_for_debit_acc, :bookings_for_credit_acc, :book_rows, :bank_rows, :bookings_todo, :bookings_by_txn_id
  attr_accessor :bookings_by_receipt_url, :bookings_by_invoice_id, :document_state_by_path
  attr_accessor :invoice_rows

  include ERB::Util
  
  DOC_FOLDER = ENV["DOC_FOLDER"]
  THUMB_FOLDER = ENV["THUMB_FOLDER"]
  EXPORT_FOLDER = ENV["EXPORT_FOLDER"]
  PREFIX = ENV['PREFIX']

  TAX_RATES = {
    "NONEU0" => 0,
    "EU19" => 19,
    "EU7" => 7
  }
  
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
        date varchar(32),
        amount_cents int,
        details text,
        comment text,
        currency varchar(4),
        receipt_url text,
        tax_code varchar(8),
        debit_account varchar(32),
        credit_account varchar(32),
        debit_txn_id varchar(32),
        credit_txn_id varchar(32),
        created_at varchar(32),
        updated_at varchar(32)
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
        vat_included varchar(6),
        replaces_id varchar(64),
        replaced_by_id varchar(64),
        created_at varchar(32),
        updated_at varchar(32)
      );
    SQL

    db.execute <<-SQL
      create table documents (
        path varchar(512) not null primary key,
        state varchar(32) not null,
        docid varchar(32),
        date varchar(23),
        sum varchar(32),
        tags TEXT,
        created_at varchar(32),
        updated_at varchar(32)
      );
    SQL
    
    db.execute <<-SQL
      create index date_idx on book(date);
    SQL

    puts "Book DB created."
  end

  def create_booking(booking)

    # FIXME hash, no direct indexing!
    
    new_row = ["",booking[:date],booking[:amount_cents],booking[:details],booking[:currency],booking[:receipt_url],booking[:tax_code],booking[:debit_account],booking[:credit_account],booking[:debit_txn_id],booking[:credit_txn_id],booking[:order_id],current_iso_date_time,current_iso_date_time,booking[:comment]]

    id_raw = "#{booking[:date]}#{booking[:amount_cents]}#{booking[:debit_account]}#{booking[:credit_account]}#{booking[:debit_txn_id]}#{booking[:credit_txn_id]}"
    id = Digest::MD5.hexdigest(id_raw)
    new_row[0] = id
    
    @book_db.execute("insert into book (id, date, amount_cents, details, currency, receipt_url, tax_code, debit_account, credit_account, debit_txn_id, credit_txn_id, order_id, created_at, updated_at, comment) 
            values (?, ?, ?, ?, ?,  ?, ?, ?, ?, ?,  ?, ?, ?, ?, ?)", new_row)

  end
  
  def create_invoice(invoice)
    new_row = [invoice[:id],invoice[:invoice_date],invoice[:amount_cents],invoice[:details],invoice[:currency],invoice[:tax_code],invoice[:customer_account],invoice[:sales_account],invoice[:order_id],invoice[:line_items],invoice[:payment_method],invoice[:customer_company],invoice[:customer_name],invoice[:customer_address_1],invoice[:customer_address_2],invoice[:customer_zip],invoice[:customer_city],invoice[:customer_state],invoice[:customer_country],invoice[:vat_included],invoice[:replaces_id],invoice[:replaced_by_id]]
    
    @book_db.execute("insert into invoices (id, invoice_date, amount_cents, details, currency, tax_code, customer_account, sales_account, order_id, line_items, payment_method, customer_company, customer_name, customer_address_1, customer_address_2, customer_zip, customer_city, customer_state, customer_country, vat_included, replaces_id, replaced_by_id) 
            values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", new_row)
  end

  def register_invoice_document(invoice, document_path)
    amount_decimal = '%.2f' % (invoice[:amount_cents]/100.0)
    tags = ["outgoing-invoice",invoice[:customer_account],invoice[:sales_account]].join(",")
    
    @book_db.execute("replace into documents (path, state, docid, date, sum, tags) values (?, ?, ?, ?, ?, ?)",
                     [document_path, "defer", invoice[:id], invoice[:invoice_date], amount_decimal, tags])
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
      select id,date,amount_cents,details,transaction_code,"EUR" from transactions where swift_code="NMSC" order by date desc;
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
          @bookings_by_txn_id[id] = new_booking # TODO double check
        end
      else
        # we got some money.
        if !bookings_for_credit_acc[acc_key][id]
          
          new_booking[:credit_account] = acc_key
          new_booking[:credit_txn_id] = row[0]
          
          @bookings_todo.push(row)
          @bookings_by_txn_id[id] = new_booking # TODO double check
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
      details = "(PayPal) #{status} #{txn_type} #{email} #{name}"
      
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
      elsif status!="Completed" && status!="Refunded" && status!="Partially Refunded"
      # TODO: not sure what to do with pending txns... maybe display somewhere else
      elsif txn_type.match(/Currency Conversion/) || txn_type.match(/Fee Reversal/)
      # TODO: later we can book these to currency exchange accounts?
      else
        if amount<0
          # negative amounts are debited from the account
          if !bookings_for_debit_acc[acc_key][id]
            # we paid money
            # there is no booking / receipt. can we create one automatically?

            new_booking[:amount_cents] = -amount # only positive amounts are transferred
            new_booking[:debit_account] = acc_key
            new_booking[:debit_txn_id] = id
            
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

  def update_booking(id, payload)
    query = "update book set debit_account=?, credit_account=?, comment=? where id=?"
    res = @book_db.execute(query, payload["debit_account"], payload["credit_account"], payload["comment"], id)

    # FIXME
    payload
  end

  def reload_documents
    ##############################################################
    ### load all document rows into memory
    
    @doc_rows = @book_db.execute <<-SQL
select path,state,docid,date,sum,tags from documents order by date desc;
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
select id,debit_account,credit_account,date,amount_cents,receipt_url,invoice_id,currency,details,comment from book order by date desc;
SQL

    Dir.mkdir(EXPORT_FOLDER) unless File.exists?(EXPORT_FOLDER)

    csv_quarters = {}
    booked_documents = {}
    
    rows.each do |row|
      receipt_paths = []
      
      row = OpenStruct.new(row)
      
      date = row[:date][0..9]
      mon = date[5..6].to_i
      quarter = (mon-1)/3+1
      subdir = "#{date[0..3]}Q#{quarter}"
      
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
        debit = row[:debit_account].gsub(":","-")
        credit = row[:credit_account].gsub(":","-")
        amount = row[:amount_cents]/100
        currency = row[:currency]

        quarters[subdir] = true

        Dir.mkdir("#{EXPORT_FOLDER}/#{subdir}") unless File.exists?("#{EXPORT_FOLDER}/#{subdir}")

        subdir_category = "expense-misc"
        if credit.match /assets/
          subdir_category = "income-misc"
        end
        
        if debit.match /sales/
          subdir_category = "income"
          
        elsif credit.match /(shipping|dhl|post)/
          subdir_category = "expense-shipping"
        elsif credit.match /consumables/
          subdir_category = "expense-consumables"
        elsif credit.match /rent/
          subdir_category = "expense-rent"
        elsif credit.match /salaries/
          subdir_category = "expense-salaries"
        elsif credit.match /services/
          subdir_category = "expense-services"
          
        elsif credit.match /(parts|packaging)/
          subdir_category = "purchase-parts-packaging"
        elsif credit.match /(tools|monitors|computers|network)/
          subdir_category = "purchase-tools"
        elsif credit.match /(furniture|kitchen)/
          subdir_category = "purchase-furniture"
        end
        
        dirname = "#{EXPORT_FOLDER}/#{subdir}/#{subdir_category}"
        Dir.mkdir(dirname) unless File.exists?(dirname)
        
        receipt.split(",").each do |r|
          unless receipt[0]=="/"
            fname = "#{date}-#{amount}#{currency}-#{r}"
            fname_full = "#{dirname}/#{fname}"
            puts "#{fname_full} <- #{credit} #{debit}"
            src = DOC_FOLDER+"/"+r
            begin
              FileUtils.cp(src,fname_full)
            rescue
              puts "ERROR: file #{src} missing!"
            end

            receipt_paths.push("#{subdir_category}/#{fname}")
            
            booked_documents[r] = true
          end
        end
      end

      # receipts saved, generate csv row

      asset_account = row[:credit_account]
      
      amount_int  = row[:amount_cents]/100
      amount_frac = row[:amount_cents]%100
      amount_frac = "0#{amount_frac}" if amount_frac<10
      
      if row[:debit_account].match /assets/
        amount_int = -amount_int
        asset_account = row[:debit_account]
      end
      amount = "#{amount_int}.#{amount_frac}"

      if !csv_quarters.include?(subdir)
        csv_quarters[subdir] = []
      end

      comment_cleaned = row[:comment].to_s.sub(/^\d{4}-\d{2}-\d{2}T[^ ]+ [^ ]+ ?/,"")
      
      csv_quarters[subdir].push([
                               row[:date][0..9],
                               row[:currency],
                               amount,
                               asset_account,
                               row[:details],
                               receipt_paths.join("\r\n"),
                               comment_cleaned,
                               row[:invoice_id]
                             ])
    end

    # FIXME these should also be booked as cash transactions
    # FIXME extract documents that have a sum but no associated booking
    
    rows = @book_db.execute <<-SQL
select path,state,docid,date,sum,tags from documents order by date desc;
SQL
    rows.each do |row|
      row = OpenStruct.new(row)

      if !booked_documents.include?(row[:path]) && row[:sum].to_f>0
        account = "unbooked"
        # FIXME: a copy of outgoing invoices ends up as unbooked, cluttering the unbooked folder
        
        if !row[:tags].nil?
          tags = row[:tags].split(",").sort
          if tags.include?("cash")
            account = "cash"
          end
        end
        
        date = row[:date][0..9]
        amount = row[:sum]
        currency = "EUR" # FIXME
        
        mon = date[5..6].to_i
        quarter = (mon-1)/3+1
        subdir = "#{date[0..3]}Q#{quarter}"
        quarters[subdir] = true

        Dir.mkdir("#{EXPORT_FOLDER}/#{subdir}") unless File.exists?("#{EXPORT_FOLDER}/#{subdir}")

        subdir_category = account
        dirname = "#{EXPORT_FOLDER}/#{subdir}/#{subdir_category}"
        Dir.mkdir(dirname) unless File.exists?(dirname)

        fname = "#{date}-#{amount}#{currency}-#{tags.join('-')}.pdf"
        fname_full = "#{dirname}/#{fname}"
        
        puts "#{fname_full} <- #{row[:path]}"
        src = DOC_FOLDER+"/"+row[:path]
        begin
          FileUtils.cp(src,fname_full)
        rescue
          puts "ERROR: file #{src} missing!"
        end
        
        if !csv_quarters.include?(subdir)
          csv_quarters[subdir] = []
        end

        # "unbooked" docs are useless in the mapping table
        if (account!="unbooked")
          csv_quarters[subdir].push([
                                      date,
                                      currency,
                                      amount,
                                      account,
                                      row[:docid],
                                      "#{subdir_category}/#{fname}",
                                      tags.join(" "),
                                      row[:invoice_id]
                                    ])
        end
      end
    end

    # generate CSV report for each quarter
    
    csv_quarters.keys.each do |quarter|
      sorted = csv_quarters[quarter].sort {|a,b| a[0] <=> b[0]}

      dirname = "#{EXPORT_FOLDER}/#{quarter}"
      Dir.mkdir(dirname) unless File.exists?(dirname)
      csv_path = "#{dirname}/table.csv"
      CSV.open(csv_path, "wb") do |csv|
        sorted.each do |r|
          csv << r
        end
      end
    end
    
    quarters.keys
  end

  def clean_bank_row_description(raw_desc)
    ### PayPal
    if raw_desc[0..7]=="(PayPal)"

      fields = {}
      email_rx = /([^ ]+@[^ ]+\.[^ ]+)/
      elements = raw_desc.split(email_rx)
      key = :status
      elements.each do |elem|
        if elem.match(email_rx)
          fields[:email] = elem
          key = :trailer
        else
          fields[key] = elem
        end
      end
      
      obj = {
        :type => :paypal,
        :details => elements.first,
        :raw => raw_desc,
        :fields => fields
      }

      return obj
    end

    ### FinTS
    #          BIC         IBAN
    bic_iban_rx = /([A-Z0-9]+ [A-Z]{2}[0-9]{2}[A-Z0-9]{8,})/
    # BELADEBEXXX DE02100500000990004716 Berliner Verkehrsbetriebe ( BVG)

    key_rx = /( [A-Z]{4}\+)/
    elements = raw_desc.split(key_rx)

    fields = {}
    key = :prefix
    elements.each do |elem|
      if elem.match(key_rx)
        key = elem.gsub(/[+ ]/,"")
      else
        if elem.match(bic_iban_rx)
          trailer = elem.split(bic_iban_rx)
          if trailer.first
            fields[key] = trailer.first
          end

          fields[:bic_iban] = trailer[1]

          if trailer.size>2
            fields[:trailer] = trailer[2..-1].join(" ")
          end
        else
          fields[key] = elem
        end
      end
    end

    obj = {
      :type => :fints,
      :details => fields["SVWZ"]||raw_desc,
      :raw => raw_desc,
      :fields => fields
    }
    
    return obj
  end

  def fetch_all_documents()
    docs = []
    
    paths = Dir.glob(DOC_FOLDER+"/**.pdf", File::FNM_CASEFOLD).sort
    paths.each do |path|
      basename = File.basename(path.downcase,".pdf")
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
        `touch \"#{textpath}\"`
        text = "Text not available (password protected PDF?)"
      end
      
      if !File.exist?(thumbpath) then
        `touch \"#{thumbpath}\"`
        text = "Thumbnail not available (password protected PDF?)"
      end

      state = "unfiled"
      booking_ids = []
      if bookings_by_receipt_url[pdfname]
        state = "booked"
        booking_ids = bookings_by_receipt_url[pdfname].map {|b| b[:id]}
      else
        state = get_document_state(pdfname)
      end

      # FIXME why are these 2 linked structures instead of one?
      
      metadata = get_document_metadata(pdfname)
      
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
    invoice[:line_items] = JSON.parse(invoice[:line_items])

    total = invoice[:amount_cents]/100.0
    tax_rate = TAX_RATES[invoice[:tax_code]] || 0
    invoice[:tax_rate] = tax_rate
    net_total = (total/(1.0+tax_rate/100.0))
    invoice[:tax_total] = '%.2f' % (net_total*tax_rate/100.0)
    invoice[:net_total] = '%.2f' % net_total
    invoice[:total] = '%.2f' % total

    # FIXME take these strings from config/locale
    # FIXME actually these should come from the template
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

    template = ERB.new(File.read("views/invoice.erb"))
    
    html = template.result_with_hash({
                 :invoice => invoice,
                 :sender_address_lines => company[:address],
                 :sender_bank_lines => company[:bank],
                 :sender_legal_lines => company[:legal],
                 :terms => terms,
                 :outro => outro,
	               :prefix => PREFIX
               })

    html
  end
  
  # call via racksh
  def register_all_invoices
    invoices = invoice_rows
    invoices.each do |invoice|
      pdf_path = "invoice-#{invoice[:order_id]}-#{invoice[:id]}.pdf"
      register_invoice_document(invoice, pdf_path)
    end
  end

  def get_stats_monthly(y, number_formatter)
    year = y.to_i
    months = []
    db = @book_db
    
    (1..12).each do |m|
      month = "%02d" % m
      
      spend_rows = db.execute <<-SQL
      select sum(amount_cents)/100 as spend from book where debit_account like "assets:%" and credit_account not like "assets:%" and date like "#{year}-#{month}-%";
      SQL
      
      earn_rows = db.execute <<-SQL
      select sum(amount_cents)/100 as earn from book where credit_account like "assets:%" and debit_account not like "assets:%" and date like "#{year}-#{month}-%";
      SQL

      spend_accounts = db.execute <<-SQL
      select sum(amount_cents)/100.0 as spend, credit_account from book where debit_account like "assets:%" and credit_account not like "assets:%" and date like "#{year}-#{month}-%" group by credit_account order by spend desc;
      SQL

      earn_accounts = db.execute <<-SQL
      select sum(amount_cents)/100.0 as earn, debit_account from book where credit_account like "assets:%" and debit_account not like "assets:%" and date like "#{year}-#{month}-%" group by debit_account order by earn desc;
      SQL

      spend = spend_rows[0]['spend']||0
      earn = earn_rows[0]['earn']||0

      months.push({
                    year:  year,
                    month: month,
                    spend: number_formatter.call(spend),
                    earn:  number_formatter.call(earn),
                    profit:  number_formatter.call(earn-spend),
                    spend_accounts: spend_accounts,
                    earn_accounts: earn_accounts,
                  })
    end

    months
  end
  
end
