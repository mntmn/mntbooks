# coding: utf-8
require 'pp'
require 'sqlite3'
require 'digest'
require 'date'
require 'sinatra'
require 'pry'
require 'csv'
require 'ostruct'
require 'zip'
require 'sinatra/base'
require 'sinatra/namespace'

require './config.rb'

require './book.rb'

class MNTBooks < Sinatra::Base
  register Sinatra::Namespace
  include ERB::Util

  DOC_FOLDER = ENV["DOC_FOLDER"]
  THUMB_FOLDER = ENV["THUMB_FOLDER"]
  EXPORT_FOLDER = ENV["EXPORT_FOLDER"]
  PREFIX = ENV['PREFIX']
    
  def initialize
    super
    @book = Book.new
  end

  def book
    @book
  end

  def make_receipt_urls(raw_receipt_url)
    receipt_urls = []
    if raw_receipt_url
      receipt_urls_raw = raw_receipt_url.split(",")
      receipt_urls_raw.each do |r|
        if r=="none"
          r = "none"
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
    receipt_urls = make_receipt_urls(b[:receipt_url])
    desc = book.clean_bank_row_description(b[:details])

    return {
      :id => b[:id],
      :date => b[:date][0..9],
      :currency => b[:currency],
      :amount_cents => b[:amount_cents],
      :debit_account => b[:debit_account],
      :credit_account => b[:credit_account],
      :details => desc[:details],
      :comment => b[:comment],
      :fields => desc[:fields],
      :raw => desc[:raw],
      :type => desc[:type],
      :receipt_urls => receipt_urls,
      :css_class => klass
    }
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
    docs = book.fetch_all_documents

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

  namespace ENV['PREFIX'] do
    get '/documents' do
      render_document_list(book, params, nil)
    end

    post '/documents' do
      book.reload_book
      docs = book.fetch_all_documents

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

    get '/invoices' do
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

    get '/invoices/new' do
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

    get '/invoices/:id' do
      # display/render an invoice

      invoice_id = params["id"]
      book.reload_book
      invoice = book.get_invoice(invoice_id)
      html = book.render_invoice_html(invoice)
      
      if params["pdf"]
        content_type 'application/pdf'
        book.create_invoice_pdf(html, invoice)
      else
        html
      end
    end

    post '/invoices' do
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
      html = book.render_invoice_html(invoice)
      pdf = book.create_invoice_pdf(html, invoice)

      # register PDF as document
      book.register_invoice_document(invoice, File.basename(pdf.path))
      
      payload.to_h.to_json
    end

    # id,date,amount_cents,details,transaction_code,currency
    def bank_row_to_hash(b)
      desc = book.clean_bank_row_description(b[3])
      
      return {
        :id => b[0], # FIXME named indexes
        :date => b[1][0..9],
        :amount_cents => b[2],
        :currency => b[5],
        :details => desc[:details],
        :type => desc[:type],
        :raw => desc[:raw],
        :fields => desc[:fields]
      }
    end

    get '/todo' do
      book.reload_book

      # collect all bank, paypal etc transactions that
      # have no booking associated with them
      rows = book.bookings_todo.map(&method(:bank_row_to_hash))
      rows = rows.sort {|a,b| b[:date] <=> a[:date]}
      
      debit_accounts = book.debit_accounts
      credit_accounts = book.credit_accounts
      
      # FIXME: move to config
      default_accounts = ["furniture","tools","consumables","packaging","computers","monitors","computers:input","computers:network","machines","parts:other","parts:reform","parts:va2000","parts:zz9000","sales:reform","sales:va2000","sales:zz9000","sales:services","sales:other","services:legal:taxadvisor","services:legal:notary","services:legal:ip","services:legal:lawyer","taxes:ust","taxes:gwst","taxes:kst","taxes:other","banking","shares","services:design","services:other","shipping","literature","capital-reserve"]
      
      accounts = (debit_accounts+credit_accounts+default_accounts).sort.uniq
      documents = book.get_all_documents.map(&:to_h).select do |d|
        d[:state]=="defer"
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

      default_comment = current_iso_date_time
      if request.env["HTTP_REMOTE_USER"] && request.env["HTTP_REMOTE_USER"].size>0
        default_comment = "#{current_iso_date_time} #{request.env['HTTP_REMOTE_USER']}"
      end
      
      erb :todo, :locals => {
            :bookings => rows,
            :documents => [documents,invoices].flatten,
            :accounts => accounts,
	          :prefix => PREFIX,
            :default_comment => default_comment
          }
    end

    get '/' do
      redirect PREFIX+"/book"
    end

    get '/stats' do

      year = params[:year].to_i
      months = book.get_stats_monthly(year)

      year_spend = months.inject(0){|sum, m| sum + m[:spend] }
      year_earn = months.inject(0){|sum, m| sum + m[:earn] }
      
      erb :stats, :locals => {
            :year => year,
            :months => months,
            :year_spend => year_spend,
            :year_earn => year_earn,
	          :prefix => PREFIX,
            :active => "stats"
          }
    end

    get '/book' do
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

    get '/ledger' do
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

    get '/export' do
      quarters = book.export_quarter
      erb :export, :locals => {
            :quarters => quarters,
            :prefix => PREFIX
          }
    end

    # FIXME all of the following need sanitization

    get '/export/:name' do
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

    get '/pdf/:name' do
      file = File.join(DOC_FOLDER, params[:name])
      send_file(file)
    end

    get '/thumbnails/:name' do
      file = File.join(THUMB_FOLDER, params[:name])
      send_file(file)
    end

    get '/dist/:name' do
      file = File.join("dist", params[:name])
      send_file(file)
    end

    post '/todo' do
      book.reload_book
      
      params.each do |k,v|
        if (id=k.match(/booking-([^\-]+)-receipt/))
          if v && v!="" && v!="null"
            id=id[1]

            # empty string account is OK
            account = params["booking-#{id}-account"]
            if !account
              account = ""
            end

            receipt_url = v
            if !receipt_url
              receipt_url = ""
            end

            new_booking = book.bookings_by_txn_id[id]
            if !new_booking.nil?
              # either account or receipt_url has to be set
              if account!="" || receipt_url!=""
                new_booking[:receipt_url] = receipt_url
                
                if (new_booking[:debit_account]) then
                  new_booking[:credit_account] = account
                else
                  new_booking[:debit_account] = account
                end

                new_booking[:comment] = params["booking-#{id}-comment"] || ""

                book.create_booking(new_booking)
              end
            else
              puts "ERROR: no booking available for txn #{id}"
            end
            
          end
        end
      end
      redirect PREFIX+"/todo"
    end
  end
  
end
