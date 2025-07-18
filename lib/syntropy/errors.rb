# frozen_string_literal: true

require 'qeweney'

module Syntropy
  class Error < StandardError
    Status = Qeweney::Status

    attr_reader :http_status

    def initialize(status, msg = '')
      super(msg)
      @http_status = status || Qeweney::Status::INTERNAL_SERVER_ERROR
    end

    class << self
      # Create class methods for common errors
      {
        not_found:          Status::NOT_FOUND,
        method_not_allowed: Status::METHOD_NOT_ALLOWED,
        teapot:             Status::TEAPOT
      }
      .each { |k, v|
        define_method(k) { |msg = ''| new(v, msg) }
      }
    end
  end

  class ValidationError < Error
    def initialize(msg)
      super(Qeweney::Status::BAD_REQUEST, msg)
    end
  end
end
