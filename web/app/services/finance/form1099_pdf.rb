# frozen_string_literal: true

require 'prawn'

Prawn::Fonts::AFM.hide_m17n_warning = true

module Finance
  # Recipient copies (Copy B) of 1099-NEC and 1099-MISC on plain paper, a substitute format for the recipient, and a
  # payer summary for the records. Copy A for the IRS (and Form 1096) must be the official scannable red forms or an
  # electronic filing, so they are not produced here. The recipient TIN is truncated to its last four digits, which
  # the IRS allows on recipient copies.
  class Form1099Pdf
    INK = '1C1917'
    MOCHA = '57534E'
    LINE = 'A8A29E'
    COPY_B_NOTE = 'This is important tax information and is being furnished to the IRS. If you are required to file a ' \
                  'return, a negligence penalty or other sanction may be imposed on you if this income is taxable and the IRS ' \
                  'determines that it has not been reported.'

    def initialize(year:, rows:, payer:)
      @year = year
      @rows = rows
      @payer = payer
    end

    def render = document.render

    def document
      @document ||= Prawn::Document.new(page_size: 'LETTER', margin: 36, info: { Title: "1099 recipient copies #{@year}", Creator: 'Rupert' }).tap do |pdf|
        pdf.font('Helvetica')
        @rows.each_with_index do |row, index|
          pdf.start_new_page if index.positive?
          copy_b(pdf, row)
        end
        pdf.start_new_page if @rows.any?
        summary(pdf)
      end
    end

    private

    def copy_b(pdf, row)
      payee = row.payee
      nec = payee.form_type == 'nec'
      title = nec ? 'Form 1099-NEC' : 'Form 1099-MISC'
      pdf.fill_color(INK)
      pdf.text("#{title} · #{@year}", size: 16, style: :bold)
      pdf.text(nec ? 'Nonemployee Compensation' : 'Miscellaneous Information', size: 10)
      pdf.text('Copy B · For Recipient', size: 10, style: :bold)
      pdf.move_down(10)
      top = pdf.cursor
      left = 0
      half = pdf.bounds.width / 2
      box(pdf, left, top, half, 70, "PAYER'S name, street address, city or town, state or province, country, ZIP or foreign postal code, and telephone no.",
        [@payer.name, @payer.street, @payer.city_line, @payer.phone].compact_blank)
      box(pdf, left, top - 70, half / 2, 32, "PAYER'S TIN", [@payer.formatted_tin])
      box(pdf, left + (half / 2), top - 70, half / 2, 32, "RECIPIENT'S TIN", [payee.tin_last4 ? "XXX-XX-#{payee.tin_last4}" : 'Not on file'])
      recipient = [payee.legal_name, payee.business_name, payee.address_line1, payee.address_line2,
                   [payee.city, [payee.state, payee.postal_code].compact_blank.join(' ')].compact_blank.join(', ')].compact_blank
      box(pdf, left, top - 102, half, 80, "RECIPIENT'S name, street address (including apt. no.), city or town, state, and ZIP", recipient)
      amount = money(row.paid_cents)
      if nec
        box(pdf, half, top, half, 50, '1 Nonemployee compensation', [amount])
        box(pdf, half, top - 50, half, 32, '2 Payer made direct sales totaling $5,000 or more of consumer products to recipient for resale', [''])
        box(pdf, half, top - 82, half, 32, '4 Federal income tax withheld', ['$0.00'])
      else
        label = Finance::TaxPayee::MISC_BOXES[payee.misc_box].to_s.delete_prefix('Box ').sub(' · ', ' ')
        box(pdf, half, top, half, 50, label, [amount])
        box(pdf, half, top - 50, half, 32, '4 Federal income tax withheld', ['$0.00'])
      end
      pdf.move_cursor_to(top - 200)
      pdf.fill_color(MOCHA)
      pdf.text(COPY_B_NOTE, size: 8)
      pdf.move_down(6)
      pdf.text("Department of the Treasury · Internal Revenue Service · #{title} (keep for your records). Payments made by card or " \
               'through a payment app are reported separately on Form 1099-K and are not included here.', size: 7)
      pdf.fill_color(INK)
    end

    def summary(pdf)
      pdf.fill_color(INK)
      pdf.text("1099 payer summary · #{@year}", size: 16, style: :bold)
      pdf.text("#{plain(@payer.name)} · EIN #{@payer.masked_tin}", size: 10)
      pdf.fill_color(MOCHA)
      pdf.text('For your records. This is not Form 1096: file Copy A and Form 1096 on the official IRS forms, or file electronically ' \
               '(IRS IRIS). Have a tax preparer review the totals before filing.', size: 8)
      pdf.fill_color(INK)
      pdf.move_down(10)
      @rows.group_by { |row| row.payee.form_type }.each do |form, rows|
        pdf.text("#{Finance::TaxPayee::FORMS[form]}: #{rows.size} #{rows.size == 1 ? 'form' : 'forms'}, #{money(rows.sum(&:paid_cents))}", size: 11, style: :bold)
        rows.each do |row|
          pdf.text("#{plain(row.payee.legal_name)} · TIN ending #{row.payee.tin_last4 || '----'} · #{plain(row.payee.form_label)} · #{money(row.paid_cents)}", size: 9)
        end
        pdf.move_down(8)
      end
      pdf.text('No payees need a 1099 for this year.', size: 10) if @rows.empty?
    end

    def box(pdf, x, y, width, height, label, lines)
      pdf.stroke_color(LINE)
      pdf.stroke_rectangle([x, y], width, height)
      pdf.bounding_box([x + 4, y - 3], width: width - 8, height: height - 6) do
        pdf.fill_color(MOCHA)
        pdf.text(plain(label), size: 6.5)
        pdf.fill_color(INK)
        lines.each { |line| pdf.text(plain(line), size: 10) }
      end
    end

    def money(cents) = "$#{ActiveSupport::NumberHelper.number_to_delimited(format('%.2f', cents.to_i / 100.0))}"
    def plain(text) = text.to_s.encode('Windows-1252', invalid: :replace, undef: :replace, replace: '?').encode('UTF-8')
  end
end
