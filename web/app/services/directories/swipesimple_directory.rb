# frozen_string_literal: true

module Directories
  # Verified native customer/user grids, independent of transaction history.
  # Authentication uses a fresh, in-memory provider session on every read.
  class SwipesimpleDirectory < SwipesimpleWeb::Client
    def fetch_directory(kind)
      login!
      response, url = get('https://swipesimple.com/transactions')
      raise Sync::Error unless url.host == 'swipesimple.com' && url.path == '/transactions'

      companies = Nokogiri::HTML(response.body).css('a[href]').filter_map { |a| a['href'][%r{\A(?:https://swipesimple\.com)?/companies/(\d+)/}, 1] }.uniq
      raise Sync::Error unless companies == [@company_id]

      path = kind == 'customers' ? '/customers' : "/companies/#{@company_id}/users"
      response, url = get("https://swipesimple.com#{path}")
      table = Nokogiri::HTML(response.body).at_css(kind == 'customers' ? '#customers-list' : '#users-list')
      raise Sync::Error unless url.path == path && table && table['data-source'] == path

      rows = []
      expected = nil
      1000.times do
        query = { format: 'json', iDisplayStart: rows.size, iDisplayLength: 100, sEcho: 1 }
        response, url = get("https://swipesimple.com#{path}?#{query.to_query}")
        raise Sync::Error unless url.host == 'swipesimple.com' && url.path == path

        document = JSON.parse(response.body)
        total = document.fetch('iTotalRecords')
        page = document.fetch('aaData')
        unless total.is_a?(Integer) && total.between?(0, 100_000) && total == document['iTotalDisplayRecords'] &&
            (expected.nil? || total == expected) && page.is_a?(Array) && page.size <= 100 && page.all? { |row| row.is_a?(Hash) }
          raise Sync::Error
        end
        expected = total
        rows.concat(page.map { |row| normalize_native(row, kind) })
        raise Sync::Error unless rows.map { |row| row['id'] }.uniq.size == rows.size && rows.size <= expected
        return rows if rows.size == expected
        raise Sync::Error if page.empty?
      end
      raise Sync::Error
    rescue CSV::MalformedCSVError, JSON::ParserError, KeyError, TypeError, NoMethodError
      raise Sync::Error
    end

    private

    def normalize_native(row, kind)
      field = kind == 'customers' ? 'customer_number' : 'link_to_user'
      fragment = Nokogiri::HTML.fragment(row.fetch(field))
      link = fragment.at_css('a[href]')
      pattern = kind == 'customers' ? %r{\A/customers/(cus_[a-zA-Z0-9]+)\z} : %r{\A/companies/#{@company_id}/users/([1-9][0-9]*)/edit\z}
      native_id = link && link['href'][pattern, 1]
      raise Sync::Error unless native_id

      name = native_text(row.fetch('name'))
      first_name, last_name = kind == 'employees' ? name.to_s.split(/\s+/, 2) : [name, nil]
      { 'id' => "#{@company_id}/#{native_id}", 'first_name' => first_name, 'last_name' => last_name,
        'email' => kind == 'customers' ? native_text(row['email']) : native_text(link.text),
        'phone' => kind == 'customers' ? native_text(row['phone']) : nil }
    end

    def native_text(value)
      return nil if value.nil?
      raise Sync::Error unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= 4096 && !value.include?("\u0000")

      Nokogiri::HTML.fragment(value).text.strip.presence
    end

    def allowed_url?(url, method)
      super || (method == 'GET' && url.scheme == 'https' && url.host == 'swipesimple.com' && url.port == 443 &&
        !url.userinfo && !url.fragment && ['/customers', "/companies/#{@company_id}/users"].include?(url.path))
    end
  end
end
