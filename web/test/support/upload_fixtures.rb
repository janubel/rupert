# frozen_string_literal: true

require 'zlib'

# Synthetic files for the Uploads inbox tests. Nothing here is real data: names,
# amounts and ids are invented, and every byte is built in memory.
module UploadFixtures
  BANK_CSV = "Date,Description,Amount,Balance\n2026-10-14,UPS STORE 123,-42.10,957.90\n2026-10-14,CARD DEPOSIT,500.00,1457.90\n2026-10-15,ACME SUPPLY,-120.00,1337.90\n"
  SWIPE_SALES_CSV = "Order ID,Date,Item,Quantity,Unit Price,Payment,Status,Currency\n" \
                    "T-1001,2026-10-14T10:00:00-04:00,Tea tin,2,12.50,Card,Completed,USD\n" \
                    "T-1002,2026-10-14T11:30:00-04:00,Mug,1,9.00,Cash,Completed,USD\n"
  ITEMS_CSV = "Name,SKU,Price,Quantity,Category\nTea tin,TEA-1,12.50,8,Tea\nMug,MUG-1,9.00,3,Gifts\n"
  QB_COA_CSV = "Account,Type,Detail Type,Description,Balance\nChecking,Bank,Checking,Main account,1000.00\nSales,Income,Sales of Product Income,,0\n"
  QB_JOURNAL_CSV = "Journal\nAccrual Basis,,,,,,\n\nTrans #,Type,Date,Num,Name,Memo/Description,Account,Debit,Credit\n" \
                   "1,Journal Entry,10/01/2026,1,,Opening,Checking,100.00,\n1,Journal Entry,10/01/2026,1,,Opening,Equity,,100.00\n"
  QB_TRIAL_CSV = "Trial Balance\nAs of October 31, 2026\n\n,Debit,Credit\nChecking,100.00,\nEquity,,100.00\n"
  QB_VENDORS_CSV = "Vendor Contact List\n\nVendor,Company,Phone,Email,Balance\nAcme Supply,Acme,555-0100,ap@example.test,0.00\n"
  IRIS_CSV = "Daily Deposits\nRecords exported: 2\nDate,Amount,Transactions,Batch,Terminal Number,Type\n" \
             "10/01/2026,100.00,4,B1,T1,Deposit\n10/02/2026,50.00,2,B2,T1,Deposit\nMonthly Total,150.00,6,,,\n"
  AUTHNET_HEADERS = ['Transaction ID', 'Transaction Status', 'Settlement Amount', 'Settlement Currency', 'Settlement Date/Time',
                     'Authorization Amount', 'Authorization Currency', 'Submit Date/Time', 'Reference Transaction ID', 'Transaction Type'].freeze
  SQUARE_CSV = "Date,Time,Category,Item,Qty,Gross Sales,Discounts,Net Sales,Transaction ID\n2026-10-14,10:00:00,Tea,Tea tin,1,12.50,0.00,12.50,TX1\n"
  TIMESHEET_CSV = "Employee,Period_start,Period_end,Status,Date,Type,Hours,Sales_cents,Commission_cents,Card_redemptions,Card_bonus_cents,Compensation_total_cents,Notes,Record_kind\n" \
                  "Pat Example,2026-10-01,2026-10-07,approved,2026-10-01,regular,8.0,0,0,0,0,0,,Standard timesheet\n"
  UNKNOWN_CSV = "alpha,beta,gamma\n1,2,3\n4,5,6\n"
  HOSTILE_CSV = "Name,Note\n=HYPERLINK(\"http://evil.test\",\"x\"),<script>alert(1)</script>\n+cmd|'/C calc'!A0,@SUM(1+1)\n-5.00,plain\n"

  def authnet_csv
    row = ['1234567890', 'Settled Successfully', '10.00', 'USD', '15-Oct-2026 10:00:00 AM EDT', '10.00', 'USD', '14-Oct-2026 10:00:00 AM EDT', '', 'Authorization and Capture']
    ([AUTHNET_HEADERS.join(',')] + [row.join(',')]).join("\n") + "\n"
  end

  # A stored (uncompressed) zip with correct CRCs, or one that lies about sizes.
  def build_zip(entries, lie_uncompressed: nil, deflate: false)
    out = String.new(encoding: Encoding::BINARY)
    central = String.new(encoding: Encoding::BINARY)
    entries.each do |name, data|
      data = data.b
      crc = Zlib.crc32(data)
      payload = deflate ? Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS).then { |z| z.deflate(data, Zlib::FINISH).tap { z.close } } : data
      method = deflate ? 8 : 0
      declared = lie_uncompressed || data.bytesize
      offset = out.bytesize
      out << [0x04034b50, 20, 0, method, 0, 0, crc, payload.bytesize, declared, name.bytesize, 0].pack('VvvvvvVVVvv') << name.b << payload
      central << [0x02014b50, 20, 20, 0, method, 0, 0, crc, payload.bytesize, declared, name.bytesize, 0, 0, 0, 0, 0, offset].pack('VvvvvvvVVVvvvvvVV') << name.b
    end
    out << central << [0x06054b50, 0, 0, entries.size, entries.size, central.bytesize, out.bytesize - central.bytesize, 0].pack('VvvvvVVv')
  end

  def build_xlsx(rows, sheet_name: 'Sheet1', shared: true, extra: {})
    strings = []
    cells = rows.each_with_index.map do |row, r|
      cols = row.each_with_index.map do |value, c|
        ref = "#{('A'.ord + c).chr}#{r + 1}"
        if value.is_a?(Numeric)
          %(<c r="#{ref}"><v>#{value}</v></c>)
        elsif shared
          strings << value.to_s
          %(<c r="#{ref}" t="s"><v>#{strings.size - 1}</v></c>)
        else
          %(<c r="#{ref}" t="inlineStr"><is><t>#{CGI.escapeHTML(value.to_s)}</t></is></c>)
        end
      end
      %(<row r="#{r + 1}">#{cols.join}</row>)
    end
    files = {
      '[Content_Types].xml' => '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>',
      'xl/workbook.xml' => %(<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="#{sheet_name}" sheetId="1" r:id="rId1"/></sheets></workbook>),
      'xl/_rels/workbook.xml.rels' => '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="x" Target="worksheets/sheet1.xml"/></Relationships>',
      'xl/worksheets/sheet1.xml' => %(<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>#{cells.join}</sheetData></worksheet>)
    }
    files['xl/sharedStrings.xml'] = %(<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">#{strings.map { |s| "<si><t>#{CGI.escapeHTML(s)}</t></si>" }.join}</sst>) if shared
    build_zip(files.merge(extra))
  end

  def upload_file(content, name, type = 'text/csv')
    Rack::Test::UploadedFile.new(StringIO.new(content), type, original_filename: name)
  end
end
