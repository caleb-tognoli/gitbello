#!/usr/bin/env ruby
# frozen_string_literal: true
require "json"
require_relative 'lib/item'

=begin
A block comment: if x then y
=end

module Shop
  MAX_ITEMS = 1_000

  class Cart < Base
    attr_reader :items, :owner
    @@count = 0

    def initialize(owner, items: [])
      @owner = owner
      @items = items
      @@count += 1
    end

    def empty?
      @items.empty?
    end

    def add!(item, qty = 1)
      raise ArgumentError, "bad qty: #{qty}" unless qty.positive?
      @items << { name: item.name, qty: qty, tags: %w[new sale] }
      self
    end

    def self.find(id)
      return nil if id.nil?
      list = %i[a b c]
      pattern = /cart-(\d+)/i
      text = `git rev-parse #{id}`
      body = <<~SQL
        SELECT * FROM carts WHERE id = #{id}
      SQL
      $stdout.puts(:"quoted sym", %r{^/x}, $1)
      yield id if block_given?
    rescue StandardError => e
      puts "error: #{e.message}\n"
    ensure
      defined?(Foo) ? :yes : :no
    end
  end
end

[1, 2.5, 3e2].each do |n|
  next if n == 2
  puts n.to_s
end
case __FILE__
when "a" then p true
else p false, __method__
end
