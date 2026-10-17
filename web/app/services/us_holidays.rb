# frozen_string_literal: true

# US federal holidays, computed (no stored data) for the admin calendar.
module UsHolidays
  module_function

  def for_year(year)
    {
      Date.new(year, 1, 1) => "New Year's Day",
      nth(year, 1, 1, 3) => 'Martin Luther King Jr. Day',
      nth(year, 2, 1, 3) => "Presidents' Day",
      last_monday(year, 5) => 'Memorial Day',
      Date.new(year, 6, 19) => 'Juneteenth',
      Date.new(year, 7, 4) => 'Independence Day',
      nth(year, 9, 1, 1) => 'Labor Day',
      nth(year, 10, 1, 2) => "Columbus / Indigenous Peoples' Day",
      Date.new(year, 11, 11) => 'Veterans Day',
      nth(year, 11, 4, 4) => 'Thanksgiving',
      Date.new(year, 12, 25) => 'Christmas Day'
    }
  end

  def between(from, to)
    (from.year..to.year).flat_map { |y| for_year(y).to_a }.select { |day, _| day.between?(from, to) }.sort
  end

  def nth(year, month, wday, count)
    first = Date.new(year, month, 1)
    first + ((wday - first.wday) % 7) + ((count - 1) * 7)
  end

  def last_monday(year, month)
    last = Date.new(year, month, -1)
    last - ((last.wday - 1) % 7)
  end
end
