# coding: utf-8
require 'pp'
require 'sqlite3'
require 'date'
require 'csv'
require 'ostruct'
require 'uri'
require 'sequel'
require 'http'

require './config.rb'

def current_iso_date_time
  Time.now.strftime('%Y-%m-%dT%H:%M:%S.%L%z')
end

class Parts  
  def initialize
    @db_filename = "parts.db"
    
    @db_exists = false
    if File.file?(@db_filename)
      @db_exists = true
    end
    
    @DB = Sequel.connect("sqlite://#{@db_filename}")
    
    if !@db_exists
      @DB.create_table :parts do
        primary_key :id
        String :manufacturer
        String :part_number
        String :category
        String :description
        String :distributor
        Integer :stock_qty
        String :location
        Float :capacitance
        Float :voltage
        Float :resistance
        Float :inductance
        Float :current
        Float :frequency
        String :tolerance
        Float :esr
        Float :rds_on
        Float :diameter
        Float :length
        Float :width
        Float :height
        Float :lead_pitch
        Integer :pins
        String :package
        String :datasheet_url
        String :image_url
        String :mouser_url
        Integer :mouser_stock_qty
        String :created_at
        String :updated_at
        String :counted_at
        String :mouser_updated_at
      end
      
      @DB.create_table :bom_items do
        primary_key :id
        Integer :bom_id
        Integer :matching_part_id
        Integer :qty
        String :manufacturer
        String :part_number
        String :references
        String :value
        String :footprint
        String :created_at
        String :updated_at
      end

      @DB.create_table :boms do
        primary_key :id
        String :name
        String :part_number
        String :created_at
        String :updated_at
      end
      
      @DB.create_table :purchase_orders do
        primary_key :id
        String :po_number
        String :supplier
        String :order_number
        String :invoice_url
        String :contact_url
        String :tracking_url
        String :state
        String :eta
        String :ordered_at
        String :received_at
        String :created_at
        String :updated_at
      end
      
      @DB.create_table :po_items do
        primary_key :id
        Integer :po_id
        String :qty
        String :manufacturer
        String :part_number
        String :notes
        Integer :sum_cents
        String :created_at
        String :updated_at
      end
      
      @DB.create_table :builds do
        primary_key :id
        String :title
        String :part_number
        String :specs
        String :order_number # link to shop
        String :invoice_number # link to invoice
        String :shipment_tracking_url # link to shipment tracking
        String :customer_email # FIXME should be a more long-lived customer_id?
        String :status
        String :status_details # markdown
        String :eta
        String :created_at
        String :updated_at
      end
    end

    puts "Parts initialized."
  end

  def get_part_fields
    @DB[:parts].columns
  end

  def get_parts
    @DB[:parts]
  end
  
  def get_boms
    @DB[:boms]
  end
  
  def get_bom_items
    @DB[:bom_items]
  end
  
  def get_pos
    @DB[:purchase_orders]
  end
  
  def get_po_items
    @DB[:po_items]
  end
  
  def get_builds
    @DB[:builds]
  end

  def lookup_mouser_part_number(api_key, pn)
    result = HTTP.post("https://api.mouser.com/api/v1/search/partnumber?apiKey=#{api_key}", :json => {
                         :SearchByPartRequest => {
                           :mouserPartNumber => pn
                         }})

    parsed = result.parse
    errors = parsed['Errors']
    if errors.size>0
      pp parsed
      return nil
    end
    results_num = parsed['SearchResults']['NumberOfResult']
    if results_num>1
      puts "WARNING: Multiple results (#{results_num}) for part #{pn}:"
      pp parsed['SearchResults']['Parts']
      #exit
    end

    # oof
    sleep 1
    
    parsed['SearchResults']['Parts']
  end

  # TODO: scope to parts that have no info
  def populate_parts_from_mouser(api_key)
    @DB[:parts].where(Sequel.lit('mouser_stock_qty is null')).where(:distributor => 'Mouser').each do |row|
      pn = row[:part_number]
      puts "Part: #{pn}"

      parts = lookup_mouser_part_number(api_key, pn)
      pp "parts:", parts

      if parts.size >= 1
        p = parts.first

        stock = 0
        if match = (p['Availability'] || '').match(/([0-9]+) In Stock/)
          stock = match.captures.first
        end

        d = p['Description'] || ''

        multipliers = {
          'p' => 1.0/(10**12),
          'n' => 1.0/(10**9),
          'u' => 1.0/(10**6),
          'm' => 1.0/(10**3),
          'K' => 1.0*(10**3),
          'M' => 1.0*(10**6),
          'G' => 1.0*(10**9),
          'T' => 1.0*(10**12),
          ''  => 1.0
        }
        
        vals = {
          :inductance => / ([0-9\.]+)([pnumKMGT]?)H[ $]/,
          :voltage => / ([0-9\.]+)([pnumKMGT]?)(V|VDC|volts)[ $]/i,
          :resistance => / ([0-9\.]+)([pnumKMGT]?)Ohms?[ $]/i,
          :capacitance => / ([0-9\.]+)([pnumKMGT]?)F[ $]/,
          :current => / ([0-9\.]+)([pnumKMGT]?)A[ $]/,
          :frequency => / ([0-9\.]+)([pnumKMGT]?)Hz[ $]/,
          :tolerance => / ([\+\-0-9\.]+)(%|ppm)[ $]/,
          :pins => / ([0-9]+[PC]|[1-2]X[0-9]+)[ $]/
        }
        vals.each do |k,v|
          if match = d.match(v)
            val,unit = match.captures
            if (k == :tolerance)
              val="#{val}#{unit}"
            elsif (k == :pins)
              if (val.include?('X'))
                val=val.split("X")
                val=val[0].to_i*val[1].to_i
              else
                val=val.to_i
              end
            elsif (!val.nil? && !multipliers[unit].nil?)
              mult = multipliers[unit]
              val = val.to_f*mult
            end
            
            vals[k] = val
            @DB[:parts].where(:part_number => pn).update(k => val)
          else
            vals[k] = 0
          end
        end

        package = ''
        packages_imp = / (01005|0201|0402|0603|0805|1008|1206|1210|1806|1812|1825|2010|2512|2920|4020)[ $]/
        packages_rx = / (SOD|SOT|SOIC|TSOP|SSOP|TSSOP|SOJ|QSOP|VSOP|DFN|QFP|LQFP|PQFP|CQFP|TQFP|LCC|MLP|MLF|PQFN|BGA|LGA|FBGA|LFBGA|TFBGA|CGA|CCGA|LLP)-?([^ $]*)[ $]/

        if match = d.match(packages_rx)
          package = match.captures.first
        elsif match = d.match(packages_imp)
          package = match.captures.first
        end

        data = {
          :mouser_stock_qty => stock,
          :manufacturer => p['Manufacturer'],
          :description => p['Description'],
          :category => p['Category'],
          :datasheet_url => p['DataSheetUrl'],
          :image_url => p['ImagePath'],
          :mouser_url => p['ProductDetailUrl'],
          :package => package
        }
        
        pp data
        
        @DB[:parts].where(:part_number => pn).update(data)
        
        # i = 0
        # p['PriceBreaks'].each do |pb|
        #   i+=1
        #   q = pb['Quantity']
        #   price = pb['Price'].split(" ").first.sub(',','.').to_f
        #   puts "pb: #{q} : #{price}"
        #   if i<4
        #     db.execute("update parts set price#{i}_mouser=?, price#{i}q_mouser=? where part_number=? limit 1",price,q,pn)
        #   end
        # end
      end
      
    end
  end

end
