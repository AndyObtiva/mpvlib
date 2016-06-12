module MPV

  typedef :pointer, :mpv_handle

  attach_function :mpv_create, [], :mpv_handle
  attach_function :mpv_initialize, [:mpv_handle], :int
  attach_function :mpv_detach_destroy, [:mpv_handle], :void
  attach_function :mpv_terminate_destroy, [:mpv_handle], :void

  attach_function :mpv_client_name, [:mpv_handle], :string

  # mpv_handle *mpv_create_client(mpv_handle *ctx, const char *name);

  # int mpv_load_config_file(mpv_handle *ctx, const char *filename);

  # void mpv_suspend(mpv_handle *ctx);
  # void mpv_resume(mpv_handle *ctx);

  attach_function :mpv_get_time_us, [:mpv_handle], :int64

  # int mpv_set_option(mpv_handle *ctx, const char *name, mpv_format format, void *data);
  attach_function :mpv_set_option_string, [:mpv_handle, :string, :string], :int

  attach_function :mpv_command, [:mpv_handle, :pointer], :int

  # int mpv_command_node(mpv_handle *ctx, mpv_node *args, mpv_node *result);
  # int mpv_command_string(mpv_handle *ctx, const char *args);

  attach_function :mpv_command_async, [:mpv_handle, :uint64, :pointer], :int
  # int mpv_command_node_async(mpv_handle *ctx, uint64_t reply_userdata, mpv_node *args);

  # attach_function :mpv_set_property, [:mpv_handle, :string, :mpv_format, :void], :int
  attach_function :mpv_set_property_string, [:mpv_handle, :string, :string], :int
  # int mpv_set_property_async(mpv_handle *ctx, uint64_t reply_userdata, const char *name, mpv_format format, void *data);

  # int mpv_get_property(mpv_handle *ctx, const char *name, mpv_format format, void *data);
  attach_function :mpv_get_property_string, [:mpv_handle, :string], :string
  # char *mpv_get_property_osd_string(mpv_handle *ctx, const char *name);
  # int mpv_get_property_async(mpv_handle *ctx, uint64_t reply_userdata, const char *name, mpv_format format);

  attach_function :mpv_observe_property, [:mpv_handle, :uint64, :string, :mpv_format], :int
  # int mpv_unobserve_property(mpv_handle *mpv, uint64_t registered_reply_userdata);

  # int mpv_request_event(mpv_handle *ctx, mpv_event_id event, int enable);

  attach_function :mpv_request_log_messages, [:mpv_handle, :string], :int

  attach_function :mpv_wait_event, [:mpv_handle, :double], MPVEvent.by_ref

  # void mpv_wakeup(mpv_handle *ctx);

  # void mpv_set_wakeup_callback(mpv_handle *ctx, void (*cb)(void *d), void *d);

  attach_function :mpv_get_wakeup_pipe, [:mpv_handle], :int

  # void mpv_wait_async_requests(mpv_handle *ctx);

  # typedef enum mpv_sub_api
  # void *mpv_get_sub_api(mpv_handle *ctx, mpv_sub_api sub_api);

  class StopEventLoop < StandardError; end

  class Handle < Base

    attr_reader :mpv_handle

    def initialize
      @mpv_handle = MPV.mpv_create
      @property_observers = {}
      @event_observers = {}
      @reply_id = 1
      MPV::Error.raise_on_failure {
        MPV.mpv_initialize(@mpv_handle)
      }
      define_finalizer(:mpv_terminate_destroy, @mpv_handle)
    end

    def client_name
      MPV.mpv_client_name(@mpv_handle)
    end

    def get_time_us
      MPV.mpv_get_time_us(@mpv_handle)
    end

    def set_option(name, value)
      #FIXME: allow non-string values
      MPV.mpv_set_option_string(@mpv_handle, name, value.to_s)
    end

    def command(*args)
      MPV::Error.raise_on_failure {
        MPV.mpv_command(@mpv_handle, FFI::MemoryPointer.from_array_of_strings(args))
      }
    end

    def command_async(*args, &block)
      reply_id = next_reply_id
      MPV::Error.raise_on_failure {
        MPV.mpv_command_async(@mpv_handle, reply_id, FFI::MemoryPointer.from_array_of_strings(args))
      }
      @property_observers[reply_id] = block
      reply_id
    end

    # FIXME: allow non-string values

    def set_property(name, data)
      MPV::Error.raise_on_failure {
        MPV.mpv_set_property_string(@mpv_handle, name, data.to_s)
      }
    end

    # FIXME: allow non-string values

    def get_property(name)
      MPV.mpv_get_property_string(@mpv_handle, name)
    end

    def observe_property(name, &block)
      reply_id = next_reply_id
      MPV::Error.raise_on_failure {
        MPV.mpv_observe_property(@mpv_handle, reply_id, name, :MPV_FORMAT_STRING)
      }
      @property_observers[reply_id] = block
      reply_id
    end

    def register_event(name, &block)
      event_id = MPVEventNames[name] or raise "No such event: #{name.inspect}"
      @event_observers[event_id] ||= []
      @event_observers[event_id] << block
      # ;;pp(name: name, block: block, event_id: event_id, observers: @event_observers)
    end

    def wait_event(timeout: -1)
      Event.new_from_mpv_event(MPV.mpv_wait_event(@mpv_handle, timeout))
    end

    def each_event(timeout: -1, raise_on_error: true, &block)
      loop do
        event = wait_event(timeout: timeout)
        raise event.error if raise_on_error && event.error
        break if event.kind_of?(MPV::Event::None)
        begin
          # ;;pp(event_id: event.event_id, observers: @event_observers[event.event_id])
          if event.reply_id && event.reply_id != 0
            observer = @property_observers[event.reply_id]
            if observer
              observer.call(event)
            end
          elsif (observers = @event_observers[event.event_id])
            # ;;warn "sending #{event.event_id} to #{observers.join.inspect}"
            observers.each { |o| o.call(event) }
          else
            yield(event)
          end
        rescue StopEventLoop
          break
        end
      end
    end

    def get_wakeup_pipe
      fd = MPV.mpv_get_wakeup_pipe(@mpv_handle)
      raise StandardError, "Couldn't get wakeup pipe from MPV" if fd < 0
      IO.new(fd)
    end

    def request_log_messages(level)
      MPV::Error.raise_on_failure {
        MPV.mpv_request_log_messages(@mpv_handle, level)
      }
    end

    private

    def next_reply_id
      @reply_id += 1
    end

  end

end