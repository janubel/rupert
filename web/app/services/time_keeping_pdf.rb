# frozen_string_literal: true

require 'prawn'
require 'prawn/table'

Prawn::Fonts::AFM.hide_m17n_warning = true

# Printable time keeping report: totals, per-person summary, then every
# person-day with scheduled versus worked hours. Built from TimeKeepingReport,
# so the PDF matches the page and the CSV for the same dates.
class TimeKeepingPdf
  INK = '1C1917'
  MOCHA = '6B7280'
  FOG = 'D6D3D1'
  HAZE = 'EDEFF0'
  ROSE_TINT = 'FDE8EA'

  def initialize(report, business_name: TenantSettings.business_name)
    @report = report
    @business_name = business_name
  end

  def render = document.render

  def document
    @document ||= Prawn::Document.new(page_size: 'LETTER', page_layout: :landscape, margin: 36,
      info: { Title: "Time keeping #{@report.from} to #{@report.to}", Creator: 'Rupert' }).tap { |pdf| draw(pdf) }
  end

  private

  def draw(pdf)
    pdf.font('Helvetica')
    pdf.fill_color(INK)
    pdf.text("#{plain(@business_name)} · Time keeping", size: 16, style: :bold)
    pdf.text("#{@report.from.strftime('%b %-d, %Y')} through #{@report.to.strftime('%b %-d, %Y')} · generated #{Time.current.strftime('%b %-d, %Y %-l:%M %p %Z')}",
      size: 9, color: MOCHA)
    pdf.move_down(8)
    totals = @report.totals
    pdf.text("Scheduled #{hours(totals[:scheduled])} h across #{totals[:shifts]} shifts · Worked #{hours(totals[:worked])} h · " \
             "C-Trax observed #{hours(totals[:ctrax])} h · #{totals[:people]} people · #{totals[:attention]} person-days need attention", size: 10)
    pdf.text('Worked hours are counted Rupert clock and Square punches (Rupert wins where they overlap). C-Trax register shifts are shown for comparison and never added.',
      size: 8, color: MOCHA)

    section(pdf, 'Staff summary')
    table(pdf, ['Staff member', 'Shifts', 'Scheduled h', 'Worked h', 'Variance', 'C-Trax h', 'Days sched.', 'Days worked', 'No punches', 'Unscheduled', 'Attention'],
      @report.staff_matrix.map { |row| [plain(row[0]), row[1], *row[2..5].map { |v| hours(v) }, *row[6..]] }, numeric_from: 1)

    section(pdf, 'Daily detail')
    rows = @report.days.map do |day|
      [day.date.strftime('%a %b %-d'), plain(day.employee_name), plain(day.schedule_label.presence || 'Not scheduled'), hours(day.scheduled_hours),
       hours(day.worked_hours), hours(day.variance), hours(day.ctrax_hours), day.status]
    end
    flagged = @report.days.each_index.select { |i| @report.days[i].attention? }
    table(pdf, ['Date', 'Staff member', 'Scheduled', 'Sched. h', 'Worked h', 'Variance', 'C-Trax h', 'Status'], rows, numeric_from: 3, numeric_to: 6, tinted: flagged)

    pdf.number_pages('Page <page> of <total>', at: [pdf.bounds.right - 120, -10], width: 120, align: :right, size: 8, color: MOCHA)
  end

  def section(pdf, title)
    pdf.move_down(14)
    pdf.text(title, size: 12, style: :bold)
    pdf.move_down(4)
  end

  def table(pdf, headers, rows, numeric_from:, numeric_to: nil, tinted: [])
    if rows.empty?
      pdf.text('Nothing scheduled or punched in this range.', size: 9, color: MOCHA)
      return
    end
    last = numeric_to || (headers.size - 1)
    pdf.table([headers] + rows.map { |row| row.map(&:to_s) }, header: true, width: pdf.bounds.width,
      cell_style: { size: 8, padding: [3, 4], border_color: FOG, border_width: 0.5 }) do |t|
      t.row(0).font_style = :bold
      t.row(0).background_color = HAZE
      t.columns(numeric_from..last).align = :right
      tinted.each { |index| t.row(index + 1).background_color = ROSE_TINT }
    end
  end

  def hours(value) = format('%.2f', value.to_f)

  # Built-in PDF fonts only cover Windows-1252; replace anything else.
  def plain(text) = text.to_s.encode('Windows-1252', invalid: :replace, undef: :replace, replace: '?').encode('UTF-8')
end
