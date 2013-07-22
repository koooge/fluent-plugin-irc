module Fluent
  class IRCOutput < Fluent::Output
    Fluent::Plugin.register_output('irc', self)

    include SetTimeKeyMixin
    include SetTagKeyMixin

    config_set_default :include_time_key, true
    config_set_default :include_tag_key, true

    config_param :host        , :string  , :default => 'localhost'
    config_param :port        , :integer , :default => 6667
    config_param :channel     , :string
    config_param :nick        , :string  , :default => 'fluentd'
    config_param :user        , :string  , :default => 'fluentd'
    config_param :real        , :string  , :default => 'fluentd'
    config_param :password    , :string  , :default => nil
    config_param :message     , :string
    config_param :out_keys do |val|
      val.split(',')
    end
    config_param :time_key    , :string  , :default => 'time'
    config_param :time_format , :string  , :default => '%Y/%m/%d %H:%M:%S'
    config_param :tag_key     , :string  , :default => 'tag'


    def initialize
      super
      require 'irc_parser'
    end

    def configure(conf)
      super
      begin
        @message % (['1'] * @out_keys.length)
      rescue ArgumentError
        raise Fluent::ConfigError, "string specifier '%s' and out_keys specification mismatch"
      end
    end

    def start
      super

      begin
        @conn = create_connection
      rescue
        raise Fluent::ConfigError, "failto connect IRC server #{@host}:#{@port}"
      end
    end

    def shutdown
      super
      @conn.close unless @conn.closed?
    end

    def emit(tag, es, chain)
      chain.next

      if @conn.closed?
        refresh_connection(@conn)
      end

      es.each do |time,record|
        filter_record(tag, time, record)
        @conn.send_message(build_message(record))
      end
    end

    private

    def create_connection
      conn = IRCConnection.connect(@host, @port)
      conn.channel = '#'+@channel
      conn.nick = @nick
      conn.user = @user
      conn.real = @real
      conn.password = @password
      conn.attach(Coolio::Loop.default)
      conn
    end

    def refresh_connection(conn)
      conn = create_connection
    end

    def build_message(record)
      values = @out_keys.map do |key|
        begin
          record.fetch(key).to_s
        rescue KeyError
          $log.warn "out_irc: the specified key '#{key}' not found in record"
          ''
        end
      end

      @message % values
    end

    class IRCConnection < Cool.io::TCPSocket
      attr_accessor :channel, :nick, :user, :real, :password

      def on_connect
        if @password
          IRCParser.message(:pass) do |m|
            m.password = @password
            write m
          end
        end
        IRCParser.message(:nick) do |m|
          m.nick   = @nick
          write m
        end
        IRCParser.message(:user) do |m|
          m.user = @user
          m.postfix = @real
          write m
        end
      end

      def on_read(data)
        data.each_line do |line|
          begin
            msg = IRCParser.parse(line)
            case msg.class.to_sym
            when :rpl_welcome
              IRCParser.message(:join) do |m|
                m.channels = @channel
                write m
              end
            when :ping
              IRCParser.message(:pong) do |m|
                m.target = msg.target
                m.body = msg.body
                write m
              end
            end
          rescue
            #TODO
          end
        end
      end

      def send_message(msg)
        IRCParser.message(:priv_msg) do |m|
          m.target = @channel
          m.body = msg
          write m
        end
      end
    end
  end
end
