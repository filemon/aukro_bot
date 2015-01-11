require 'yaml'
require 'open-uri'
require 'savon'
require 'base64'
require 'paint'


module Aukro

  TIME_TO_END_GAP = 25
  SHORT_SLEEP_TIME = 10
  DEEP_SLEEP_TIME = 45*60

  class Auction

    attr_accessor :url, :id, :actual_price, :finish_time, :winner

    def initialize(url, max, bidder)
      @url = url
      @max_price = max
      @bidder = bidder
      @bidder.set_auction_details(self)
    end

    def increase_bid
      @actual_price = @bidder.get_actual_price(self)
      if time_for_bidding?
        if @actual_price < @max_price && @winner != @bidder.myself
          @actual_price = @bidder.increase_price(self, @max_price)
          puts "Bid increased for #{@url} to #{@actual_price}"
          @winner = @bidder.get_winner(self)
        else
          puts "No action taken. Current winner: #{@winner}, price: #{@actual_price}, my max: #{@max_price}"
        end
      end
      puts self
    end

    def is_open?
      @finish_time - @bidder.get_server_time > 0
    end

    def time_to_wakeup?
      @finish_time - @bidder.get_server_time <= Aukro::DEEP_SLEEP_TIME + 15*60
    end

    def time_for_bidding?
      @finish_time - @bidder.get_server_time <= Aukro::TIME_TO_END_GAP
    end

    def to_s
      result = "#{Time.new}: id: #{@id}, url: #{@url}, open: #{is_open?}, actual_price: #{@actual_price}, max_price: #{@max_price}, winner: #{@winner}, finish_time: #{Time.at(@finish_time)}"
      if @winner != @bidder.myself
        @actual_price > @max_price ? result = Paint[result, :red] : result = Paint[result, :yellow]
      else
        result = Paint[result, :green]
      end
      result
    end

  end

  class Bidder


    def initialize(auctions_config)
      @aukro_config = YAML.load_file('aukro.yml')
      @soap_client = Savon.client(wsdl: @aukro_config['web_api_wsdl'],
                                  log_level: @aukro_config['soap_debug'] ? :debug : :info,
                                  log: @aukro_config['soap_debug'])

      @aukro_config['api_local_version'] = api_local_version @aukro_config['web_api_key'], @aukro_config['aukro_country_code']

      request_start = Time.now
      login
      request_finish = Time.now
      @heuristic_clock_difference = Time.now.to_i - @session[:server_time].to_i + (request_finish-request_start).to_i

      @auctions = []
      auctions_config = YAML.load_file(auctions_config)
      auctions_config['auctions'].each do |auction_config|
        @auctions << Thread.new(Auction.new(auction_config['url'], auction_config['max'], self)) do |auction|
          puts "New auction thread started for #{auction}"
          while auction.is_open?
            STDOUT.flush
            begin
              auction.increase_bid
            rescue => exception
              puts exception
              sleep(30) #try to recover from connection problems
              retry
            end
            if auction.time_to_wakeup?
              sleep(Aukro::SHORT_SLEEP_TIME)
            else
              sleep(Aukro::DEEP_SLEEP_TIME)
            end
          end
          puts "Auction status: #{auction}"
        end
      end

      @auctions.each { |auction| auction.join }
    end

    def get_actual_price (auction)
      page = open(auction.url).read
      if page =~ %r{<strong id="priceValue".*class="price" itemprop="price">([0-9\s,.]*)( K.*)</strong>}m
        $1.gsub(/[^0-9,.]/, '').to_i
      end
    end

    def increase_price(auction, price)
      begin
        response = @soap_client.call(:do_bid_item,
                                     :message => {
                                         :'session-handle' => @session[:session_handle_part],
                                         :'bid-it-id' => auction.id,
                                         :'bid-user-price' => price,
                                         :'bid-quantity' => 1,
                                         :'bid-buy-now' => 0})
      rescue Savon::SOAPFault => detail
        if detail.to_hash[:fault][:faultcode] == 'ERR_NO_SESSION'
          login
          retry
        end
        raise
      end

      response.body[:do_bid_item_response][:bid_price]
    end

    def login
      response = @soap_client.call(:do_login_enc,
                                   :message => {
                                       :'user-login' => @aukro_config['username'],
                                       :'user-hash-password' => Utils.encode_pass(@aukro_config['password']),
                                       :'country-code' => @aukro_config['aukro_country_code'],
                                       :'webapi-key' => @aukro_config['web_api_key'],
                                       :'local-version' => @aukro_config['api_local_version']})

      puts Paint['Logged in successfully', :green]
      @session = response.body[:do_login_enc_response]
    end


    def set_auction_details(auction)
      auction.id = get_auction_id(auction.url)
      auction_details = get_auction_details(auction)
      auction.finish_time = auction_details[:it_ending_time].to_i
      #xsd structure demarshalled if winner is empty
      auction.winner = auction_details[:it_high_bidder_login] unless auction_details[:it_high_bidder_login].is_a? Hash
      auction.actual_price = get_actual_price(auction)
    end

    def get_winner(auction)
      get_auction_details(auction)[:it_high_bidder_login]
    end


    def get_auction_id(url)
      if url =~ /-i([0-9]*?)\.htm/m
        $1.to_i
      else
        fail 'Incorrect auction URL, item id not present'
      end
    end

    def get_server_time
      Time.now.to_i + @heuristic_clock_difference
    end

    def myself
      @aukro_config['my_hidden_name']
    end

#    private

    def api_local_version(webapi_key, country_code)
      response = @soap_client.call(:do_query_sys_status,
                                   :message => {
                                       :'sysvar' => 3,
                                       :'country-id' => country_code,
                                       :'webapi-key' => webapi_key
                                   })

      response.body[:do_query_sys_status_response][:ver_key]
    end

    def get_auction_details(auction)
      begin
        response = @soap_client.call(:do_get_items_info,
                                     :message => {
                                         :'session-handle' => @session[:session_handle_part],
                                         :'items-id-array' => {item: auction.id},
                                         :'get-desc' => 1})

          #response example -> {:do_get_items_info_response=>{:array_item_list_info=>{:item=>{:item_info=>{:it_id=>"3056922889", :it_country=>"56", :it_name=>"Nálepky z kulatých zápalek - J.Sheinost - stoletá", :it_price=>"99", :it_bid_count=>"1", :it_ending_time=>"1362597337", :it_seller_id=>"5259792", :it_seller_login=>"lesok1", :it_seller_rating=>"17365", :it_starting_time=>"0", :it_starting_price=>"99", :it_quantity=>"1", :it_foto_count=>"1", :it_reserve_price=>"0", :it_location=>"Praha 6", :it_buy_now_price=>"0", :it_buy_now_active=>"0", :it_high_bidder=>"0", :it_high_bidder_login=>"s...v", :it_description=>"<p><strong><span style=\"font-size: large;\">č.1297 - stav viz foto -&nbsp;n&aacute;lepky z těch nejstar&scaron;&iacute;ch kulat&yacute;ch krabiček - 10x3,7cm&nbsp;a 10x1,5cm&nbsp;- n&aacute;dhern&yacute; star&yacute;&nbsp;original</span></strong></p><p><strong><span style=\"font-size: large;\">&nbsp;</span></strong></p><p><strong><span style=\"font-size: large;\">-&nbsp;o pravosti nemůže b&yacute;t pochyb a poskytuji na ni jakoukoliv z&aacute;ruku </span></strong></p><p><strong><span style=\"font-size: large;\">- n&aacute;lepky jsou tak&eacute; v kr&aacute;sn&eacute;m stavu a na podložce jsou uchyceny pouze kous&iacute;čkem pap&iacute;rov&eacute; filatelistick&eacute; n&aacute;lepky.takže lehce odstraniteln&eacute; bez po&scaron;kozen&iacute;. Jedn&aacute; se o několik vz&aacute;cn&yacute;ch expon&aacute;tů ze sb&iacute;rky po jednom z vět&scaron;&iacute;ch filumenistů v Čech&aacute;ch z Prahy 1 , jehož rodina se dostala do finančn&iacute; t&iacute;sně,a tak vol&iacute; tuto cestu prodeje.</span></strong></p><p><strong><span style=\"font-size: large;\">&nbsp;</span></strong></p><p><strong><span style=\"font-size: large;\">V současnosti najdete na m&yacute;ch aukro str&aacute;nk&aacute;ch v&iacute;ce podobn&yacute;ch n&aacute;lepek - jednotliv&eacute; i cel&eacute; serie + i nějak&eacute; kompletn&iacute; i rozložen&eacute; krabičky - pro sběratele jedinečn&aacute; př&iacute;ležitost.</span></strong></p>", :it_options=>"1178878374", :it_state=>"29", :it_is_eco=>"0", :it_hit_count=>"56", :it_postcode=>{:"@xsi:type"=>"xsd:string"}, :it_vat_invoice=>"0", :it_bank_account1=>"1709262133 / 0800", :it_bank_account2=>"235048981 / 0300", :it_starting_quantity=>"1", :it_is_for_guests=>"0", :it_has_product=>"0", :it_order_fulfillment_time=>"0", :it_ending_info=>"1", :it_is_allegro_standard=>"1", :it_is_new_used=>"0", :"@xsi:type"=>"typens:ItemInfo"}, :item_cats=>{:item=>[{:cat_level=>"0", :cat_id=>"8531", :cat_name=>"Sběratelství", :"@xsi:type"=>"typens:ItemCatList"}, {:cat_level=>"1", :cat_id=>"8478", :cat_name=>"Ostatní", :"@xsi:type"=>"typens:ItemCatList"}, {:cat_level=>"2", :cat_id=>"12814", :cat_name=>"Filumenie", :"@xsi:type"=>"typens:ItemCatList"}, {:cat_level=>"3", :cat_id=>"69215", :cat_name=>"Zápalkové nálepky", :"@xsi:type"=>"typens:ItemCatList"}], :"@xsi:type"=>"SOAP-ENC:Array", :"@soap_enc:array_type"=>"typens:ItemCatList[4]"}, :item_images=>{:"@xsi:type"=>"SOAP-ENC:Array", :"@soap_enc:array_type"=>"typens:ItemImageList[0]"}, :item_attribs=>{:"@xsi:type"=>"SOAP-ENC:Array", :"@soap_enc:array_type"=>"typens:AttribStruct[0]"}, :item_postage_options=>{:"@xsi:type"=>"SOAP-ENC:Array", :"@soap_enc:array_type"=>"typens:PostageStruct[0]"}, :item_payment_options=>{:pay_option_transfer=>"1", :pay_option_on_delivery=>"1", :pay_option_allegro_pay=>"1", :pay_option_see_desc=>"0", :pay_option_payu=>"0", :pay_option_escrow=>"0", :pay_option_qiwi=>"0", :"@xsi:type"=>"typens:ItemPaymentOptions"}, :item_company_info=>{:company_first_name=>{:"@xsi:type"=>"xsd:string"}, :company_last_name=>{:"@xsi:type"=>"xsd:string"}, :company_name=>{:"@xsi:type"=>"xsd:string"}, :company_address=>{:"@xsi:type"=>"xsd:string"}, :company_postcode=>{:"@xsi:type"=>"xsd:string"}, :company_city=>{:"@xsi:type"=>"xsd:string"}, :company_nip=>{:"@xsi:type"=>"xsd:string"}, :"@xsi:type"=>"typens:CompanyInfoStruct"}, :item_product_info=>{:product_id=>"0", :product_name=>{:"@xsi:type"=>"xsd:string"}, :product_description=>{:"@xsi:type"=>"xsd:string"}, :product_images_list=>{:"@xsi:type"=>"SOAP-ENC:Array", :"@soap_enc:array_type"=>"xsd:string[0]"}, :product_parameters_group_list=>{:"@xsi:type"=>"SOAP-ENC:Array", :"@soap_enc:array_type"=>"typens:ProductParametersGroupStruct[0]"}, :"@xsi:type"=>"typens:ProductStruct"}, :"@xsi:type"=>"typens:ItemInfoStruct"}, :"@xsi:type"=>"SOAP-ENC:Array", :"@soap_enc:array_type"=>"typens:ItemInfoStruct[1]"}, :array_items_not_found=>{:"@xsi:type"=>"SOAP-ENC:Array", :"@soap_enc:array_type"=>"xsd:long[0]"}, :array_items_admin_killed=>{:"@xsi:type"=>"SOAP-ENC:Array", :"@soap_enc:array_type"=>"xsd:long[0]"}}, :"@soap_env:encoding_style"=>"http://schemas.xmlsoap.org/soap/encoding/"}
      rescue Savon::SOAPFault => detail
        if detail.to_hash[:fault][:faultcode] == 'ERR_NO_SESSION'
          login
          retry
        end
        raise
      end
      response.body[:do_get_items_info_response][:array_item_list_info][:item][:item_info]
    end
  end

  class Utils
    def self.encode_pass(password)
      Base64.encode64(Digest::SHA256.digest(password)).chomp
    end
  end

end
