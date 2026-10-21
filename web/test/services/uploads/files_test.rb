# frozen_string_literal: true

require 'test_helper'

class UploadsFilesTest < ActiveSupport::TestCase
  include UploadFixtures

  test 'filenames lose paths, control and direction characters and leading dots' do
    assert_equal 'passwd.csv', Uploads::Filename.clean('../../etc/passwd.csv')
    assert_equal 'a.csv', Uploads::Filename.clean("C:\\temp\\a.csv")
    assert_equal 'eviltxt.csv', Uploads::Filename.clean("evil\u202Etxt.csv")
    assert_equal 'hidden.csv', Uploads::Filename.clean('...hidden.csv')
    assert_equal 'a_b.csv', Uploads::Filename.clean("a\u0000;b.csv")
    assert_equal 'upload', Uploads::Filename.clean('   ')
    assert_operator Uploads::Filename.clean("#{'x' * 500}.csv").length, :<=, Uploads::Filename::MAX_LENGTH
    assert_equal '.csv', Uploads::Filename.extension(Uploads::Filename.clean('Report.CSV')).downcase
    assert_equal '.exe', Uploads::Filename.extension(Uploads::Filename.clean('statement.csv.exe'))
  end

  test 'text decoding handles BOMs and UTF-16 and refuses binary' do
    assert_equal ["a,b\n", 'UTF-8 (BOM)'], Uploads::TextDecoder.decode("\xEF\xBB\xBFa,b\n").then { |d| [d.text, d.encoding] }
    utf16 = "\uFEFFa,b\n".encode('UTF-16LE').b
    assert_equal "a,b\n", Uploads::TextDecoder.decode(utf16).text
    assert_equal "Caf\u00e9", Uploads::TextDecoder.decode("Caf\xE9".b).text
    assert_match(/assumed/, Uploads::TextDecoder.decode("Caf\xE9".b).encoding)
    assert_nil Uploads::TextDecoder.decode("MZ\x90\x00\x03\x00\x00\x00".b)
    assert_nil Uploads::TextDecoder.decode(Random.new(1).bytes(2000).tr("\x00", "\x01") + "\x00")
  end

  test 'spreadsheet formula starts are marked and defused, plain numbers are left alone' do
    %w[=1+1 +cmd @SUM(A1) =HYPERLINK("x")].each { |value| assert Uploads::Cell.formula_like?(value), value }
    assert Uploads::Cell.formula_like?("\tcmd")
    ['-5.00', '+12', '(3.50)', 'plain', '$-1'].each { |value| assert_not Uploads::Cell.formula_like?(value), value }
    assert_equal "'=1+1", Uploads::Cell.neutralize('=1+1')
    assert_equal 'plain', Uploads::Cell.neutralize('plain')
    assert_equal 201, Uploads::Cell.display('x' * 500).length
  end

  test 'a real workbook is read without evaluating anything' do
    bytes = build_xlsx([['Name', 'Qty'], ['=1+1', 2], ['Tea', 3]])
    reader = Uploads::XlsxReader.new(bytes)
    assert_equal ['Sheet1'], reader.sheets.map(&:name)
    assert_equal [%w[Name Qty], ['=1+1', '2'], %w[Tea 3]], reader.rows
    assert_equal [['x']], Uploads::XlsxReader.new(build_xlsx([['x']], shared: false)).rows
    assert_not reader.macros?
    assert Uploads::XlsxReader.new(build_xlsx([['x']], extra: { 'xl/vbaProject.bin' => 'x' })).macros?
  end

  test 'zip bombs and damaged or encrypted workbooks are refused by arithmetic before inflating' do
    big = '0' * (30 * 1024 * 1024)
    bomb = build_zip({ '[Content_Types].xml' => '<a/>', 'xl/workbook.xml' => big }, deflate: true)
    assert_operator bomb.bytesize, :<, 200_000
    assert_raises(Uploads::ZipInspector::Error) { Uploads::XlsxReader.new(bomb) }

    liar = build_zip({ '[Content_Types].xml' => '<a/>', 'xl/workbook.xml' => '<b/>' }, lie_uncompressed: 200 * 1024 * 1024)
    assert_raises(Uploads::ZipInspector::Error) { Uploads::XlsxReader.new(liar) }

    assert_raises(Uploads::ZipInspector::Error) { Uploads::XlsxReader.new('PK not really a zip') }
    assert_raises(Uploads::ZipInspector::Error) { Uploads::XlsxReader.new(build_zip({ 'other.txt' => 'x' })) }
    assert_raises(Uploads::ZipInspector::Error) { Uploads::XlsxReader.new(build_zip({ '../evil' => 'x' })) }
    many = (1..600).to_h { |i| ["p#{i}.txt", 'x'] }
    assert_raises(Uploads::ZipInspector::Error) { Uploads::XlsxReader.new(build_zip(many)) }
  end

  test 'a part that inflates beyond its declared size is cut off' do
    payload = build_zip({ '[Content_Types].xml' => '<a/>', 'xl/workbook.xml' => 'x' * 100_000 }, deflate: true, lie_uncompressed: 50)
    zip = Uploads::ZipInspector.new(payload)
    assert_raises(Uploads::ZipInspector::Error) { zip.read('xl/workbook.xml') }
  end

  test 'validation checks the bytes against the claimed format' do
    assert_nil Uploads::Validator.check(BANK_CSV, 'csv')
    assert_match(/binary/, Uploads::Validator.check("MZ\x00\x00".b, 'csv'))
    assert_nil Uploads::Validator.check('%PDF-1.7 fake', 'pdf')
    assert_match(/PDF/, Uploads::Validator.check('<html>', 'pdf'))
    assert_nil Uploads::Validator.check('{"a":[1]}', 'json')
    assert_match(/not valid JSON/, Uploads::Validator.check('{"a":', 'json'))
    assert_match(/not valid JSON/, Uploads::Validator.check('[' * 50 + ']' * 50, 'json'))
    assert_nil Uploads::Validator.check(build_xlsx([['a']]), 'xlsx')
    assert_match(/Not a valid Excel/, Uploads::Validator.check('PK\x03\x04 nope', 'xlsx'))
  end
end
