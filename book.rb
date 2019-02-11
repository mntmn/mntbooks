# coding: utf-8
require 'pp'
require 'sqlite3'
require 'digest'
require 'date'
require 'sinatra'
require 'pry'
require 'csv'

include ERB::Util

DOC_FOLDER = ENV["DOC_FOLDER"]
THUMB_FOLDER = ENV["THUMB_FOLDER"]
INVOICES_CSV_FOLDER = ENV["INVOICES_CSV_FOLDER"]
EXPORT_FOLDER = ENV["EXPORT_FOLDER"]
PREFIX = ENV["PREFIX"]

class Book
  attr_accessor :acc_id, :bookings_for_debit_acc, :bookings_for_credit_acc, :book_rows, :bank_rows, :bookings_todo, :bookings_by_txn_id
  attr_accessor :bookings_by_receipt_url, :bookings_by_invoice_id, :invoices_by_customer, :document_state_by_path
  
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
    @invoices_by_customer = {}
    @document_state_by_path = {}
    
    if File.file?(@db_filename)
      @db_exists = true
    end

    @book_db = SQLite3::Database.new @db_filename

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
        credit_txn_id varchar(32),
        order_id  varchar (32),
        invoice_id  varchar (32),
        invoice_payment_method  varchar (32),
        invoice_company TEXT,
        invoice_lines TEXT,
        invoice_name  TEXT,
        invoice_address_1 TEXT,
        invoice_address_2 TEXT,
        invoice_zip TEXT,
        invoice_city  TEXT,
        invoice_state TEXT,
        invoice_country TEXT
      );
    SQL

    db.execute <<-SQL
      create table documents (
        path varchar(512) not null primary key,
        state varchar(32) not null,
        docid varhcar(32),
        date varchar(23),
        sum varchar(23),
        tags TEXT
      );
    SQL

    # credit_account empty if unpaid
    
    db.execute <<-SQL
      create index date_idx on book(date);
    SQL

    puts "Book DB created."
  end

  def create_booking(booking,auto_route)
    new_row = ["",booking[:date],booking[:amount],booking[:details],booking[:currency],booking[:receipt_url],booking[:tax_code],booking[:debit_account],booking[:credit_account],booking[:debit_txn_id],booking[:credit_txn_id],booking[:order_id],booking[:invoice_id],booking[:invoice_lines],booking[:invoice_payment_method],booking[:invoice_company],booking[:invoice_name],booking[:invoice_address_1],booking[:invoice_address_2],booking[:invoice_zip],booking[:invoice_city],booking[:invoice_state],booking[:invoice_country]]

    customer_routing = false
    orig_debit_acc = nil
    orig_credit_acc = nil

    # FIXME only if correct credit_account, i.e. paypal/bank
    if auto_route && booking[:debit_account].match(/^customer:/)
      # incoming -> assets:#{bank-acc}
      # assets -> customer:...
      orig_debit_acc = booking[:debit_account]
      customer_routing = true
      new_row[7] = "external"

    #elsif booking[:credit_account].match(/^customer:/)
    #  # FIXME: when? for refunds?
    #  orig_credit_acc = booking[:credit_account]
    #  customer_routing = true
    #  booking[:credit_account] = "external"
    end
    
    id_raw = "#{new_row[1]}#{new_row[2]}#{new_row[7]}#{new_row[8]}#{new_row[9]}#{new_row[10]}"
    id = Digest::MD5.hexdigest(id_raw)
    new_row[0] = id
    
    pp "INSERT",new_row

    # TODO: should be a transaction
    
    @book_db.execute("INSERT INTO book (id, date, amount_cents, details, currency, receipt_url, tax_code, debit_account, credit_account, debit_txn_id, credit_txn_id, order_id, invoice_id, invoice_lines, invoice_payment_method, invoice_company, invoice_name, invoice_address_1, invoice_address_2, invoice_zip, invoice_city, invoice_state, invoice_country) 
            VALUES (?, ?, ?, ?, ?,  ?, ?, ?, ?, ?,  ?, ?, ?, ?, ?,  ?, ?, ?, ?, ?,  ?, ?, ?)", new_row)

    if customer_routing
      new_row[3]="Route \##{id} to #{orig_debit_acc}"
      new_row[7]=new_row[8] # debit <- credit
      new_row[8]=orig_debit_acc
      
      id_raw = "#{new_row[1]}#{new_row[2]}#{new_row[7]}#{new_row[8]}#{new_row[9]}#{new_row[10]}"
      id = Digest::MD5.hexdigest(id_raw)
      new_row[0] = id
      
      @book_db.execute("INSERT INTO book (id, date, amount_cents, details, currency, receipt_url, tax_code, debit_account, credit_account, debit_txn_id, credit_txn_id, order_id, invoice_id) 
            VALUES (?, ?, ?, ?, ?,  ?, ?, ?, ?, ?,  ?, ?, ?)", new_row[0..12])
    end
  end

  def link_receipt(db,id,receipt_url)
    db.execute("update book set receipt_url = ? where id = ?", receipt_url, id)
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
    @document_metadata_by_path = {}
    
    @book_rows = @book_db.execute <<-SQL
select id,debit_account,debit_txn_id,credit_account,credit_txn_id,date,amount_cents,details,receipt_url,currency,invoice_id from book order by date desc;
SQL

    @book_rows.each do |row|
      #pp row
      if !@bookings_for_debit_acc[row[1]]
        @bookings_for_debit_acc[row[1]]={}
      end
      if !@bookings_for_credit_acc[row[3]]
        @bookings_for_credit_acc[row[3]]={}
      end
      @bookings_for_debit_acc[row[1]][row[2]]=row
      @bookings_for_credit_acc[row[3]][row[4]]=row

      receipt_urls = []
      receipt_urls = row[8].split(",") unless row[8].nil?
      invoice_id = row[10]

      receipt_urls.each do |receipt_url|
        if !@bookings_by_receipt_url[receipt_url]
          @bookings_by_receipt_url[receipt_url]=[]
        end
        @bookings_by_receipt_url[receipt_url].push(row)
      end
      
      if !@bookings_by_invoice_id[invoice_id]
        @bookings_by_invoice_id[invoice_id]=[]
      end
      @bookings_by_invoice_id[invoice_id].push(row)

      debit_account = row[1]
      if debit_account.match(/^customer:/)
        if !@invoices_by_customer[debit_account]
          @invoices_by_customer[debit_account]=[]
        end
        @invoices_by_customer[debit_account].push({
                                                 book_id: row[0],
                                                 receipt_url: receipt_urls[0], # FIXME
                                                 amount_cents: row[6],
                                                 date: row[5]
                                               })
      end
    end

    @doc_rows = @book_db.execute <<-SQL
select path,state,docid,date,sum,tags from documents;
SQL

    @doc_rows.each do |doc|
      @document_state_by_path[doc[0]]=doc[1]
      metadata={
        path: doc[0],
        state: doc[1],
        docid: doc[2],
        date: doc[3],
        sum: doc[4],
        tags: doc[5]
      }
      @document_metadata_by_path[doc[0]]=metadata
      @documents.push(metadata)
    end
    @documents.sort_by! do |d|
      d[:docid] || d[:path]
    end

    @bank_rows = @bank_acc_db.execute <<-SQL
      select id,date,amount_cents,details,transaction_code,"EUR" from transactions order by date desc;
    SQL

    acc_key = "assets:bank-#{acc_id}"
    if !@bookings_for_debit_acc[acc_key]
      @bookings_for_debit_acc[acc_key]={}
    end
    if !@bookings_for_credit_acc[acc_key]
      @bookings_for_credit_acc[acc_key]={}
    end

    # TODO create some kind of rule system for this
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
        :amount => amount,
        :details => details,
        :currency => "EUR",
        :tax_code => ""
      }

      #puts "BANK|#{id}|#{details}"

      if amount<0
        # negative amounts are debited from the account
        if !bookings_for_debit_acc[acc_key][id]
          # we paid money
          # there is no booking / receipt. can we create one automatically?

          new_booking[:amount] = -amount # only positive amounts are transferred
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
        :amount => amount,
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
      else
        if amount<0
          # negative amounts are debited from the account
          if !bookings_for_debit_acc[acc_key][id]
            # we paid money
            # there is no booking / receipt. can we create one automatically?

            new_booking[:amount] = -amount # only positive amounts are transferred
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

  def get_document_state(pdfname)
    @document_state_by_path[pdfname] || "unfiled"
  end

  def get_document_metadata(pdfname)
    @document_metadata_by_path[pdfname] || {}
  end

  def get_all_documents()
    @documents
  end

  def update_document_state(pdfname, state)
    if get_document_state(pdfname) == "unfiled"
      @book_db.execute("insert into documents (path,state) values (?,?)",[pdfname, state])
    else
      @book_db.execute("update documents set state=? where path=?",[state, pdfname])
    end
    @document_state_by_path[pdfname] = state
  end
  
  def update_document_metadata(pdfname, docid, date, sum, tags)
    puts "update metadata:",[docid,date,sum,tags,pdfname]
    if get_document_state(pdfname) == "unfiled"
      update_document_state(pdfname, "defer")
    end
    @book_db.execute("update documents set docid=?,date=?,sum=?,tags=? where path=?",[docid,date,sum,tags,pdfname])
  end

  def debit_accounts
    @book_db.execute("select distinct(debit_account) from book").flatten.reject(&:nil?)
  end
  
  def credit_accounts
    @book_db.execute("select distinct(credit_account) from book").flatten.reject(&:nil?)
  end

  # FIXME some filenames can contain ",", sanitize!
  
  def export_quarter
    rows = @book_db.execute <<-SQL
select id,debit_account,credit_account,date,amount_cents,receipt_url,invoice_id,currency from book order by date desc;
SQL

    rows.each do |row|
      receipt = row[5]
      if row[1].nil?
        #puts "Warning: no debit_account"
      elsif row[2].nil?
        #puts "Warning: no credit_account"
      elsif receipt.nil? || !receipt || receipt == "none"
        #puts "Warning: no receipt"
      elsif row[1]=="external" || row[2]=="external"
      elsif row[1].match(/^customer:/)
      else
        receipt = receipt.split('#')[0]
        date = row[3][0..9]
        debit = row[1].gsub(":","-")
        credit = row[2].gsub(":","-")
        amount = row[4]/100
        currency = row[7]

        mon = date[5..6].to_i
        quarter = (mon-1)/3+1
        subdir = "#{date[0..3]}Q#{quarter}"

        Dir.mkdir(EXPORT_FOLDER) unless File.exists?("export")
        Dir.mkdir("#{EXPORT_FOLDER}/#{subdir}") unless File.exists?("export/#{subdir}")
        
        dirname = "#{EXPORT_FOLDER}/#{subdir}/#{date}-#{amount}#{currency}-#{debit}-#{credit}"
        Dir.mkdir(dirname) unless File.exists?(dirname)
        
        receipt.split(",").each do |r|
          puts "#{dirname} <- #{r}"
          src = DOC_FOLDER+"/"+r
          FileUtils.cp(src,dirname)
        end
      end
    end

    "OK"
  end
end

def clean_bank_row_description(raw_desc)
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
    :id => b[0],
    :date => b[1][0..9],
    :amount => b[2],
    :currency => b[5],
    :details => desc[:details],
    :details_line_1 => desc[:details_line_1]||desc[:details],
    :details_line_2 => desc[:details_line_2],
    :fields => desc[:fields],
    :iban => desc[:iban]
  }
end

# select id,debit_account,debit_txn_id,credit_account,credit_txn_id,date,amount,details,receipt_url,currency from book;
def book_row_to_hash(b)  
  klass = ""
  amount = b[6]
  if !b[3].nil? && b[3].match("assets:bank-")
    klass = "credit-bank"
  end

  desc = clean_bank_row_description(b[7])

  return {
    :id => b[0],
    :date => b[5][0..9],
    :currency => b[9].sub("EUR","€"),
    :amount => amount,
    :debit_account => b[1],
    :credit_account => b[3],
    :details => desc[:details],
    :details_line_1 => desc[:details_line_1]||desc[:details],
    :details_line_2 => desc[:details_line_2],
    :receipt_url => b[8],
    :css_class => klass
  }
end

book = Book.new

# FIXME: revive or delete this
# make a list of all available PDF files for linking as receipts
def match_receipts(rows, receipts)
  result_matches = {}
  tag_map = {}
  tags_to_remove = {}
  receipts.each do |r|
    tags = r.gsub(".pdf","").split("-").map(&:downcase)
    if tags.last.to_i.to_s == tags.last
      if tags.last.to_i < 100*50000 # FIXME threshold?
        tags[-1] = "price-"+tags.last
      end
    end
    if tags.first.to_i.to_s == tags.first && tags.first[0..3]==Date.today.year.to_s
      tags[0] = "date-"+tags[0]
    end
    
    tags.each do |t|
      if tag_map[t]
        tags_to_remove[t] = true
      else
        tag_map[t] = r
      end
    end
  end

  tags_to_remove.each do |k,v|
    tag_map.delete(k)
  end

  # rows are the unbooked bank rows
  rows.each do |r|
    matches = []
    
    d = r[:details].gsub(/[\/+\-]+/," ")
    if (match_row = tag_map["price-"+r[:amount].to_s])
      matches.push(match_row)
    else
      words = d.split(" ")
      words.each do |word|
        if (word.size>4 && match_row = tag_map[word.downcase])
          puts("matched: '#{word}' for #{r}")
          matches.push(match_row)
        end
      end
    end

    # todo histogram to pick best match
    if matches.size>0
      pp [r,matches]
      result_matches[r[:id]]=matches[0]
    end
  end
  
  return result_matches
end


# for each pdf:
# - check if in book table
#
# can i use /docs for this?
# add a filter to docs: unfiled
#
#
#- if unfiled, buttons:
#  - "unpaid invoice"
#  - "rotate 90"
#  - "rotate 270"
#  - "trash"
#  - "archive"

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
    booking_id = nil
    if book.bookings_by_receipt_url[pdfname]
      state = "booked"
      booking_id = book.bookings_by_receipt_url[pdfname]
    else
      state = book.get_document_state(pdfname)
    end

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
                booking_id: booking_id
              })
  end

  docs
end

get PREFIX+'/documents' do
  book.reload_book
  docs = fetch_all_documents(book)

  if params["state"]
    docs = docs.select do |d|
      d[:state] == params["state"]
    end
  end
  
  if params["cachebust"]
    docs.each do |d|
      if d[:id] == params["cachebust"]
        d[:thumbnail]+="?v="+Random.new.rand.to_s
        break
      end
    end
  end
  
  erb :documents, :locals => {
        :docs => docs,
	:prefix => PREFIX
      }
end

post PREFIX+'/documents' do
  book.reload_book
  docs = fetch_all_documents(book)

  if !File.exists?("rotate-bak")
    Dir.mkdir("rotate-bak")
  end

  cachebust_id = ""

  pp params

  target_state = "unfiled"
  target_docid = ""

  docs.each do |doc|
    new_state = params["doc-#{doc[:id]}-state"]
    name = doc[:title]
    
    if new_state && new_state.downcase.match(/^(todo|archive|defer)$/)
      new_state.downcase!
      book.update_document_state(name, new_state)
    end

    new_docid = params["doc-#{doc[:id]}-docid"]
    new_tags =  params["doc-#{doc[:id]}-tags"]
    new_date =  params["doc-#{doc[:id]}-date"]
    new_sum =   params["doc-#{doc[:id]}-sum"]

    if params["doc-#{doc[:id]}-metadata"]
      target_state=book.get_document_state(name)
      book.update_document_metadata(name,new_docid,new_date,new_sum,new_tags)
      target_docid=doc[:id]
    end

    rotate90 =  params["doc-#{doc[:id]}-rotate-90"]
    rotate180 = params["doc-#{doc[:id]}-rotate-180"]
    rotate270 = params["doc-#{doc[:id]}-rotate-270"]

    backup_path = "rotate-bak/#{name}"

    if rotate90 || rotate180 || rotate270
      # backup original
      cmd = "cp \"#{doc[:path]}\" \"#{backup_path}\""
      puts "BACKUP|#{cmd}"
      `#{cmd}`

      # refresh thumbnail
      thumbname = File.basename(doc[:title],".pdf")+".png"
      thumbpath = THUMB_FOLDER+"/"+thumbname
      `rm \"#{thumbpath}\"`
    end
    
    if rotate90
      cmd = "pdftk \"#{backup_path}\" cat 1-endeast output \"#{doc[:path]}\""
      puts "ROTATE|#{cmd}"
      `#{cmd}`
    elsif rotate180
      cmd = "pdftk \"#{backup_path}\" cat 1-endsouth output \"#{doc[:path]}\""
      puts "ROTATE|#{cmd}"
      `#{cmd}`
    elsif rotate270
      cmd = "pdftk \"#{backup_path}\" cat 1-endwest output \"#{doc[:path]}\""
      puts "ROTATE|#{cmd}"
      `#{cmd}`
    end
    
    if rotate90 || rotate180 || rotate270
      reload_docs = true
      cachebust_id = doc[:id]
    end
  end
  
  redirect PREFIX+"/documents?state=#{target_state}&cachebust=#{cachebust_id}#doc#{target_docid}"
end

def import_outgoing_invoices(book)
  # date,amount,currency,account1,account2,paymentMethod,company,name,addr1,addr2,zip,city,state,country,ordernum,items

  book.reload_book
  docs = fetch_all_documents
  
  paths = Dir.glob(INVOICES_CSV_FOLDER+"/**.csv").sort
  paths.each do |path|
    iid = path.split("-").last.sub(".csv","").to_i
    year = File.basename(path).split("-").first.to_i
    
    csv = CSV.new(File.read(path), {:headers=>true})
    csv.each do |row|
      # FIXME: manual and shop csv header names differ :/
      # FIXME: invoice id is implict and only in the file name .______.

      formatted_iid = "#{year}-#{iid.to_s.rjust(4,'0')}"
      
      payment_method = row[5]
      items = row[15]

      if row[6] && row[6].gsub(/[^a-zA-Z0-9]/,"").size>3
        customer_id = row[6].gsub(/[^a-zA-Z0-9]/,"").downcase.gsub(/(gmbh|ug|gbr|inc)/,"")
      else
        customer_id = row[7].gsub(/[^a-zA-Z0-9]/,"").downcase
      end

      debit_acc = "customer:#{customer_id}"
      
      credit_acc = "sales:other"
      # project heuristics
      if items.match("Reform") then
        credit_acc = "sales:reform"
      elsif items.match("ZZ9000") then
        credit_acc = "sales:zz9000"
      elsif items.match("VA2000") then
        credit_acc = "sales:va2000"
      end

      tax_code = "NONEU-0"
      if row[4]=="8400"
        tax_code = "EU-19"
      end
      
      data = {
        date: row[0].split(" ").first,
        amount: (row[1].to_f*100).to_i,
        currency: row[2],
        invoice_id: formatted_iid,
        invoice_payment_method: row[5],
        invoice_company: row[6],
        invoice_name: row[7],
        invoice_address_1: row[8],
        invoice_address_2: row[9],
        invoice_zip: row[10],
        invoice_city: row[11],
        invoice_state: row[12],
        invoice_country: row[13],
        order_id: row[14],
        invoice_lines: row[15],
        debit_account: debit_acc,
        credit_account: credit_acc,
        debit_txn_id: formatted_iid,
        tax_code: tax_code,
        details: "Invoice #{formatted_iid}"
      }

      docs.each do |d|
        if d[:title].match(formatted_iid) then
          data[:receipt_url] = d[:path].split("/").last
        end
      end

      iid+=1

      booking = book.bookings_by_invoice_id[formatted_iid]
      if booking
        puts "  '-- existing booking: #{booking[0]}"
      else
        book.create_booking(data,false)
        puts "  '-- new booking created"
      end
    end
  end

  "OK"
end

get PREFIX+'/invoices' do
  content_type 'text/plain;charset=utf8'

  invoices = import_outgoing_invoices(book)

  invoices.to_s
end

get PREFIX+'/todo' do
  book.reload_book
  
  rows = book.bookings_todo.map(&method(:bank_row_to_hash))

  debit_accounts = book.debit_accounts
  credit_accounts = book.credit_accounts
  
  default_accounts = ["furniture","tools","consumables","packaging","computers","monitors","computers:input","computers:network","machines","parts:other","parts:reform","parts:va2000","parts:zz9000","sales:reform","sales:va2000","sales:zz9000","sales:services","sales:other","services:legal:taxadvisor","services:legal:notary","services:legal:ip","services:legal:lawyer","taxes:ust","taxes:gwst","taxes:kst","taxes:other","banking","shares","services:design","services:other","shipping","literature","capital-reserve"]
  
  accounts = (debit_accounts+credit_accounts+default_accounts).sort.uniq
  documents = JSON.generate(book.get_all_documents)
  
  erb :todo, :locals => {
        :bookings => rows,
        :documents => documents,
        :accounts => accounts,
	:prefix => PREFIX
      }
end

get PREFIX+'/' do
  redirect PREFIX+"/book"
end

get PREFIX+'/book' do
  book.reload_book
  
  erb :book, :locals => {
        :bookings => book.book_rows.map(&method(:book_row_to_hash)),
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
    if h[:amount]<0
      out+="\t#{h[:debit_account]||"unknown"}\t\t#{h[:currency]} #{-h[:amount]/100.0}\n"
      out+="\t#{h[:credit_account]||"unknown"}\n\n"
    else
      out+="\t#{h[:credit_account]||"unknown"}\t\t#{h[:currency]} #{h[:amount]/100.0}\n"
      out+="\t#{h[:debit_account]||"unknown"}\n\n"
    end
  end

  return out
end

get PREFIX+'/export' do
  book.export_quarter
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
            
            book.create_booking(new_booking,true)
          else
            puts "ERROR: no booking available for txn #{id}"
          end
        end
      end
    end
  end
  redirect PREFIX+"/todo"
end
