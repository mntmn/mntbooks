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
require './parts.rb'

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
    @parts = Parts.new
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
      
      invoices=book.invoice_rows.sort_by {|i| i[:invoice_date]}
      invoices.reverse!
      
      invoices=invoices.map do |i|
        i[:receipt_urls] = []
        i[:receipt_urls].push(PREFIX+"/invoices/#{i.id}")
        i[:receipt_urls].push(PREFIX+"/invoices/#{i.id}?pdf=1")

        date = Date.parse(i[:invoice_date])
        month_key = "#{date.year}-#{date.month.to_s.rjust(2,'0')}"
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
      payload["vat_included"] = payload["vat_included"].to_s # FIXME questionable

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
      
      accounts = (debit_accounts+credit_accounts+DEFAULT_ACCOUNTS).sort.uniq
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
      nf = Proc.new do |n|
        "%0.3f" % (n/1000.0)
      end
      
      year = params[:year].to_i
      months = book.get_stats_monthly(year, nf)

      # FIXME work with decimal
      year_spend = months.inject(0){|sum, m| sum + m[:spend].to_f }
      year_earn = months.inject(0){|sum, m| sum + m[:earn].to_f }
      year_profit = year_earn-year_spend
      
      erb :stats, :locals => {
            :year => year,
            :months => months,
            :year_spend => nf.call(year_spend),
            :year_earn => nf.call(year_earn),
            :year_profit => nf.call(year_profit),
	          :prefix => PREFIX,
            :active => "stats"
          }
    end

    get '/book' do
      book.reload_book

      # autocomplete data
      debit_accounts  = book.debit_accounts
      credit_accounts = book.credit_accounts
      accounts = (debit_accounts+credit_accounts+DEFAULT_ACCOUNTS).sort.uniq
      documents = book.get_all_documents.map(&:to_h).select do |d|
        d[:state]=="defer"
      end
      
      months={}
      bookings=book.book_rows.map(&method(:book_row_to_hash))

      filter_year = nil
      filter_month = nil
      filter_null_account = false
      
      if params["year"]
        filter_year = params["year"].to_i
      end
      if params["month"]
        filter_month = params["month"].to_i
      end
      if params["null_account"]
        filter_null_account = (params["null_account"].to_i == 1)
      end
      
      bookings=bookings.select do |b|
        pass = true
        if filter_month
          date = Date.parse(b[:date])
          pass = (date.month == filter_month)
        end
        if pass && filter_year
          date = Date.parse(b[:date])
          pass = (date.year == filter_year)
        end
        if pass && filter_null_account
          pass = b[:credit_account].nil? || b[:credit_account].size < 1 || b[:debit_account].nil? || b[:debit_account].size<1
        end
        pass
      end
      
      bookings=bookings.map do |b|
        date = Date.parse(b[:date])
        month_key = "#{date.year}-#{date.month}"
        if !months[month_key]
          months[month_key]={
            :bookings => [],
            :earn_cents => 0,
            :spend_cents => 0
          }
        end
        months[month_key][:bookings].push(b)

        # pseudo summing
        if b[:currency]=="EUR" # FIXME kludge
          if b[:debit_account].to_s.match("assets:") && !b[:credit_account].to_s.match("assets:")
            months[month_key][:spend_cents]+=b[:amount_cents]
            b[:css_class] = "negative"
          elsif !b[:debit_account].to_s.match("assets:") && (b[:credit_account].to_s.match("assets:"))
            months[month_key][:earn_cents]+=b[:amount_cents]
            b[:css_class] = "positive"
          end
        end
        
        b
      end
      
      erb :book, :locals => {
            :months => months,
            :accounts => accounts,
            :documents => documents,
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

    post '/book/:id' do
      content_type 'application/json'
      
      id = params["id"]

      book.reload_book
      request.body.rewind
      payload = JSON.parse(request.body.read)

      result = book.update_booking(id, payload)

      result.to_h.to_json
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

    class PartsHelper
      def format_val(val,unit)
        return "" if val.nil?

        chrs = ['G','M','K','','m','µ','n','p']
        i = 3
        while (val>999 && i>0)
          val/=1000.0
          i -= 1
        end

        if (i==3)
          while (val<0.1 && i<chrs.size-1)
            val*=1000.0
            i += 1
          end
        end
        
        "#{val.round(2)}#{chrs[i]}#{unit}"
      end

      def format_datetime(val)
        return "" if val.nil?
        val.sub("T"," ")[0..15]
      end
    end
    
    get '/parts' do
      parts = @parts.get_parts.order(:category,:manufacturer,:part_number).all
      
      erb :parts, :locals => {
            :fmt => PartsHelper.new,
            :parts => parts,
            :edit_id => nil,
            :part => {},
            :highlight => params[:highlight].to_i,
            :prefix => PREFIX,
            :notification => params[:notification]
          }
    end

    post '/parts-delete' do
      parts = @parts.get_parts

      part = parts.where(:id => params[:id]).first
      
      parts.where(:id => part[:id]).delete

      redirect PREFIX+"/parts?notification=Part #{part[:part_number]} deleted."
    end
    
    post '/parts' do
      parts = @parts.get_parts

      data = {}
      params.keys.each do |k|
        if params[k].size>0 && k!="save"
          data[k] = params[k]
        end
      end
      part_id=params[:id].to_i

      if part_id>0
        if !params["stock_qty"].nil? && params["stock_qty"].size>0
          data[:counted_at] = current_iso_date_time
        end
        data[:updated_at] = current_iso_date_time
        parts.where(:id => part_id).update(data)
      else
        data[:created_at] = current_iso_date_time
        part_id = parts.insert(data)
      end
      
      redirect PREFIX+"/parts?highlight=#{part_id}##{part_id}"
    end
    
    get '/parts-find' do
      parts = @parts.get_parts

      parts = parts.where(:part_number => params[:part_number]).order(:category,:manufacturer,:part_number).all

      found_part = parts.first || {}

      # prepare new part form
      if parts.size<1
        found_part = {
          part_number: params[:part_number]
        }
      end
      
      erb :parts, :locals => {
            :fmt => PartsHelper.new,
            :parts => parts,
            :prefix => PREFIX,
            :edit_id => found_part[:id],
            :highlight => found_part[:id],
            :part => found_part,
            :notification => nil
          }
    end
    
    post '/parts-bulk' do
      parts = @parts.get_parts

      bulk = params[:bulk]

      part_id = 0
      i = 0
      bulk.lines.each do |line|
        line = line.chomp
        puts "#{i}: [#{line}]"
        words = line.split(/\s+/)
        puts "#{i}: [#{words.join(',')}]"
        i += 1

        words = words.map do |w|
          if w.size<1
            nil
          else
            w
          end
        end.flatten

        words = words.map do |w|
          w.gsub('"','')
        end
        
        data = {
          :part_number => words[0],
          :stock_qty => words[1].to_i,
          :counted_at => current_iso_date_time,
          :updated_at => current_iso_date_time
        }

        existing_parts = parts.where(:part_number => words[0])
        if existing_parts.count > 0
          part_id = existing_parts.first[:id]
          parts.where(:id => part_id).update(data)
        else
          data[:created_at] = current_iso_date_time
          part_id = parts.insert(data)
        end
      end

      redirect PREFIX+"/parts?added=#{part_id}"
    end
    
    get '/parts-populate' do
      @parts.populate_parts_from_mouser(ENV["MOUSER_API_KEY"])
      
      redirect PREFIX+"/parts"
    end

    get '/boms' do
      boms = @parts.get_boms.all

      erb :boms, :locals => {
            :boms => boms,
            :prefix => PREFIX
          }
    end
    
    post '/boms' do
      boms = @parts.get_boms

      data = {
        :name => params["name"],
        :part_number => params["part_number"]
      }

      if params["id"].size>0
        boms.where(:id => params["id"]).update(data)
        redirect PREFIX+"/boms"
      else
        id = boms.insert(data)
        redirect PREFIX+"/boms?notification=Created BOM #{id}."
      end
    end

    def collect_bom_items(result_items, bom, matching_parts, recursive, level)
      items = @parts.get_bom_items.where(:bom_id => bom[:id]).order(:references, :value).all
      
      items.each do |item|
        item[:level] = level
        item[:po_item] = {}
        item[:po] = {}
        
        result_items.push(item.to_h)
        parts = @parts.get_parts.where(:part_number => item[:part_number]).all
        
        if parts.size>0
          matching_parts[item[:id]] = parts.first
        end

        # look up any matching items currently on order
        po_items = @parts.get_po_items.where(:part_number => item[:part_number]).all
        # fixme aggregate multiple orders
        po_items.each do |poi|
          po = @parts.get_pos.where(:id => poi[:po_id]).first
          item[:po_item] = poi
          item[:po] = po
        end

        if recursive
          # check if there is a sub-BOM
          sub_boms = @parts.get_boms.where(:part_number => item[:part_number])
          if sub_boms.count>0
            item[:sub_bom] = true
            collect_bom_items(result_items, sub_boms.first, matching_parts, true, level+1)
          end
        end
      end
      
      result_items
    end
    
    get '/boms/:id' do
      items = []
      matching_parts = {}
      recursive = params[:tree] || false

      bom = @parts.get_boms.where(:id => params[:id]).first
      collect_bom_items(items, bom, matching_parts, recursive, 0)

      calculate_builds = 1
      calculate_builds = params[:builds].to_i if params[:builds]

      edit_bom_item = {}
      if params[:edit]
        edit_bom_item = @parts.get_bom_items.where(:bom_id => params[:id]).where(:id => params[:edit]).first
      end
      
      erb :bom, :locals => {
            :bom => bom,
            :bom_id => bom[:id],
            :edit_bom_item => edit_bom_item,
            :bom_items => items,
            :matching_parts => matching_parts,
            :builds => calculate_builds,
            :prefix => PREFIX
          }
    end
    
    post '/boms/:bom_id/items' do
      bom = @parts.get_boms.where(:id => params[:bom_id]).first
      bom_items = @parts.get_bom_items

      data = {
        :bom_id => bom[:id],
        :qty => params["qty"],
        :references => params["references"],
        :manufacturer => params["manufacturer"],
        :part_number => params["part_number"],
        :value => params["value"],
        :footprint => params["footprint"]
      }
      
      existing = bom_items.where(:id => params[:id])
      if existing.count > 0
        bom_items.where(:id => params[:id]).update(data)
      else
        bom_items.insert(data)
      end
      
      redirect PREFIX+"/boms/#{bom[:id]}"
    end
    
    post '/boms/:bom_id/bulk' do
      bom = @parts.get_boms.where(:id => params[:bom_id]).first
      bom_items = @parts.get_bom_items

      table = CSV.parse(params[:csv], headers: true)

      table.each do |row|
        data = {
          :bom_id => bom[:id],
          :qty => row['Quantity'] || row['qty'],
          :value => row['Value'] || row['value'],
          :references => row['Reference'] || row['references'],
          :manufacturer => row['Manufacturer'] || row['manufacturer'],
          :footprint => row['Footprint'] || row['footprint'],
          :part_number => row['Manufacturer_No'] || row['part_number']
        }
        if !data[:references].nil? && data[:references].size>0
          bom_items.insert(data)
        end
      end
      
      redirect PREFIX+"/boms/#{bom[:id]}"
    end

    get '/purchase-orders' do
      pos = @parts.get_pos.all

      erb :pos, :locals => {
            :pos => pos,
            :prefix => PREFIX
          }
    end
    
    get '/purchase-orders/:id' do
      items = []
      matching_parts = {}

      po = @parts.get_pos.where(:id => params[:id]).first
      items = @parts.get_po_items.where(:po_id => params[:id]).all

      edit_po_item = {}
      if params[:edit]
        edit_po_item = @parts.get_po_items.where(:po_id => params[:id]).where(:id => params[:edit]).first
      end
      
      erb :po, :locals => {
            :po => po,
            :po_id => po[:id],
            :edit_po_item => edit_po_item,
            :po_items => items,
            :matching_parts => matching_parts,
            :prefix => PREFIX
          }
    end
    
    post '/purchase-orders' do
      pos = @parts.get_pos

      data = {
        :supplier => params["supplier"],
        :po_number => params["po_number"],
        :order_number => params["order_number"],
        :invoice_url => params["invoice_url"],
        :contact_url => params["contact_url"],
        :tracking_url => params["tracking_url"],
        :eta => params["eta"],
        :ordered_at => params["ordered_at"],
        :received_at => params["received_at"],
        :state => params["state"]
      }

      if params["id"].size>0
        pos.where(:id => params["id"]).update(data)
        redirect PREFIX+"/purchase-orders"
      else
        id = pos.insert(data)
        redirect PREFIX+"/purchase-orders?notification=Created PO #{id}."
      end
    end
    
    post '/purchase-orders/:po_id/items' do
      po = @parts.get_pos.where(:id => params[:po_id]).first
      po_items = @parts.get_po_items

      data = {
        :po_id => po[:id],
        :qty => params["qty"],
        :manufacturer => params["manufacturer"],
        :part_number => params["part_number"],
        :sum_cents => params["sum_cents"],
        :notes => params["notes"]
      }
      
      existing = po_items.where(:id => params[:id])
      if existing.count > 0
        po_items.where(:id => params[:id]).update(data)
      else
        po_items.insert(data)
      end
      
      redirect PREFIX+"/purchase-orders/#{po[:id]}"
    end
    
  end
  
end
