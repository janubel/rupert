# frozen_string_literal: true

require 'test_helper'

class UploadsIntakeTest < ActiveSupport::TestCase
  include UploadFixtures

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @admin = users(:regular_user)
    Current.user = @admin
  end

  teardown { Current.reset }

  test 'the inbox audit is a structured upload event with hash, size and outcome, never contents or file names' do
    io = StringIO.new
    tap_logger = Logger.new(io, level: Logger::INFO)
    tap_logger.formatter = Logger::Formatter.new.tap { |formatter| formatter.extend(OpsLog::Formatter) }
    Rails.logger.broadcast_to(tap_logger)
    OpsLog.with_format('json') { intake(BANK_CSV, 'Smith-payroll.csv') }
    event = io.string.lines.map { |line| JSON.parse(line) }.find { |line| line['event'] == 'upload' }
    assert event, io.string
    assert_equal 64, event['sha256'].size
    assert_equal BANK_CSV.bytesize.to_s, event['byte_size']
    assert_equal 'web', event['origin']
    assert event['outcome'].present?
    ['Smith', 'payroll', BANK_CSV.lines[1].strip].each { |text| assert_not_includes io.string, text }
  ensure
    Rails.logger.stop_broadcasting_to(tap_logger)
  end

  def intake(content, name = 'statement.csv', **options)
    Uploads::Intake.call(StringIO.new(content), filename: name, origin: 'web', actor: @admin, **options)
  end

  test 'keeps the original byte for byte, encrypted, and recognizes it' do
    bytes = "\xEF\xBB\xBF#{BANK_CSV}".b
    result = intake(bytes)
    upload = result.upload
    assert result.created
    assert_equal bytes, upload.original_bytes
    assert_equal Digest::SHA256.hexdigest(bytes), upload.sha256
    assert_equal 'recognized', upload.status
    assert_equal 'bank_statement', upload.importer_key
    assert_equal 4, upload.row_count
    assert_not_includes Upload.connection.select_value("SELECT content_base64 FROM uploads WHERE id = #{upload.id}"), Base64.strict_encode64(bytes)
    assert_equal 'Regular User', upload.uploaded_by_name if @admin.display_name == 'Regular User'
  end

  test 'the same bytes are stored once and the repeat is recorded as a duplicate' do
    first = intake(BANK_CSV).upload
    second = intake(BANK_CSV, 'renamed.csv')
    assert_not second.created
    assert_equal 'duplicate', second.upload.status
    assert_equal first.id, second.upload.duplicate_of_id
    assert_not second.upload.retained
    assert_nil second.upload.content_base64
    assert_equal 1, Upload.where(retained: true).count
    assert_equal 2, Upload.count
  end

  test 'the same file in another workspace is its own upload' do
    intake(BANK_CSV)
    other = Tenant.create!(name: 'Other uploads tenant', subdomain: 'other-uploads')
    Current.tenant = other
    assert_equal 0, Upload.count
    assert intake(BANK_CSV).created
    Current.tenant = @tenant
    assert_equal 1, Upload.count
  end

  test 'unsupported, empty, binary, oversized and malformed files are refused with a reason and not kept' do
    {
      'run.exe' => ['MZ binary', /Unsupported file type/],
      'noext' => ['abc', /Unsupported file type/],
      'empty.csv' => ['', /empty/],
      'fake.csv' => ["MZ\x90\x00\x03\x00".b, /binary/],
      'fake.pdf' => ['<html>not a pdf</html>', /PDF/],
      'bad.json' => ['{"a":', /not valid JSON/],
      'bad.xlsx' => ['not a zip', /Excel/]
    }.each do |name, (content, pattern)|
      result = intake(content, name)
      assert_equal 'rejected', result.upload.status, name
      assert_match(pattern, result.upload.reason, name)
      assert_not result.upload.retained, name
      assert_nil result.upload.content_base64, name
    end
  end

  test 'a file over the size cap is refused without reading it all' do
    stub_const(Uploads::Limits, :MAX_FILE_BYTES, 100) do
      result = intake('x' * 500, 'big.csv')
      assert_equal 'rejected', result.upload.status
      assert_match(/larger than/, result.upload.reason)
      assert_nil result.upload.content_base64
    end
  end

  test 'a zip bomb disguised as a workbook is refused' do
    bomb = build_zip({ '[Content_Types].xml' => '<a/>', 'xl/workbook.xml' => '0' * (30 * 1024 * 1024) }, deflate: true)
    result = intake(bomb, 'budget.xlsx')
    assert_equal 'rejected', result.upload.status
    assert_match(/compressed far more|more than 100 MiB/, result.upload.reason)
    assert_not result.upload.retained
  end

  test 'a hostile file name is only ever a label' do
    result = intake(BANK_CSV, "../../../etc/cron.d/x‮;rm -rf.csv")
    assert_no_match(%r{[/\\‮;]}, result.upload.filename)
    assert_match(/\.csv\z/, result.upload.filename)
  end

  test 'logs carry hashes, sizes and outcomes but never file contents or the file name' do
    io = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    intake("Date,Description,Amount\n2026-10-14,SECRETPAYEE,-1.00\n", 'secret-name.csv')
    Rails.logger = previous
    logged = io.string
    assert_match(/upload action=received/, logged)
    assert_match(/sha256=\h{64}/, logged)
    assert_no_match(/SECRETPAYEE|secret-name/, logged)
    assert_no_match(/SECRETPAYEE/, ActivityLog.where(tenant_id: @tenant.id).pluck(:details).join)
  end

  test 'a flood is stopped by the daily limit instead of growing the table' do
    stub_const(Uploads::Intake, :DAILY_LIMIT, 2) do
      intake(BANK_CSV)
      intake(UNKNOWN_CSV, 'a.csv')
      before = Upload.count
      assert_raises(Uploads::Intake::Error) { intake(SQUARE_CSV, 'b.csv') }
      assert_equal before, Upload.count
    end
  end

  test 'a retained file must fit the remaining storage allowance and duplicates use no more bytes' do
    stub_const(Uploads::Intake, :STORAGE_LIMIT, BANK_CSV.bytesize) do
      first = intake(BANK_CSV)
      assert first.created
      assert_equal 'duplicate', intake(BANK_CSV, 'copy.csv').upload.status
      assert_raises(Uploads::Intake::Error) { intake(UNKNOWN_CSV, 'more.csv') }
      assert_equal BANK_CSV.bytesize, Upload.where(retained: true).sum(:byte_size)
      assert_equal 2, Upload.count
    end
  end

  test 'a new original cannot overrun a partially used storage allowance' do
    stub_const(Uploads::Intake, :STORAGE_LIMIT, BANK_CSV.bytesize + UNKNOWN_CSV.bytesize - 1) do
      intake(BANK_CSV)
      assert_raises(Uploads::Intake::Error) { intake(UNKNOWN_CSV, 'more.csv') }
      assert_equal 1, Upload.count
      assert_equal BANK_CSV.bytesize, Upload.where(retained: true).sum(:byte_size)
    end
  end

  test 'capacity consumed during validation is rechecked before retaining a file' do
    assert_capacity_rechecked(nil)
  end

  test 'capacity consumed during validation is rechecked before recording a rejection' do
    assert_capacity_rechecked(['not_text', 'Refused fixture'])
  end

  def assert_capacity_rechecked(validation_result)
    stub_const(Uploads::Intake, :DAILY_LIMIT, 1) do
      # Models another request committing after the initial capacity read but
      # before this request obtains SQLite's writer lock. No private data needed.
      validation = lambda do |*|
        Upload.create!(filename: 'other.txt', origin: 'web', status: 'rejected', byte_size: 0)
        validation_result
      end
      Uploads::Validator.stub(:problem, validation) do
        assert_raises(Uploads::Intake::Error) { intake(BANK_CSV) }
      end
      assert_equal 1, Upload.count
      assert_equal 0, Upload.where(retained: true).count
    end
  end

  test 'a workspace that is not active cannot receive files' do
    Current.tenant = Tenant.create!(name: 'Paused uploads tenant', subdomain: 'paused-uploads', status: 'suspended')
    assert_raises(Uploads::Intake::Error) { intake(BANK_CSV) }
  end

  def stub_const(mod, name, value)
    old = mod.const_get(name)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
    yield
  ensure
    mod.send(:remove_const, name)
    mod.const_set(name, old)
  end
end
