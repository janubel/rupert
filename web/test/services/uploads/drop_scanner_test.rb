# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

class UploadsDropScannerTest < ActiveSupport::TestCase
  include UploadFixtures

  setup do
    @tenant = tenants(:default_tenant)
    Current.tenant = @tenant
    @root = Dir.mktmpdir('drop-root')
    @incoming = File.join(@root, @tenant.subdomain, 'incoming')
    FileUtils.mkdir_p(@incoming, mode: 0o700)
    @old = Time.now - 60
  end

  teardown do
    FileUtils.remove_entry(@root)
    Current.reset
  end

  def drop(name, content, age: 60)
    path = File.join(@incoming, name)
    File.binwrite(path, content)
    File.utime(Time.now - age, Time.now - age, path)
    path
  end

  def scan = Uploads::DropScanner.call(root: @root)

  test 'it is off unless explicitly enabled' do
    assert_not Uploads::DropScanner.enabled?
    drop('a.csv', BANK_CSV)
    UploadsDropScanJob.perform_now
    assert_equal 0, Upload.count
  end

  test 'files are taken through the same intake, then moved out of incoming' do
    drop('statement.csv', BANK_CSV)
    report = scan
    assert_equal 1, report.taken
    upload = Upload.last
    assert_equal 'drop', upload.origin
    assert_equal 'recognized', upload.status
    assert_nil upload.uploaded_by_id
    assert_empty Dir.children(@incoming)
    assert_equal ["#{upload.id}-statement.csv"], Dir.children(File.join(@root, @tenant.subdomain, 'processed'))
  end

  test 'a repeat is recorded as a duplicate and a refused file is quarantined under a harmless name' do
    drop('one.csv', BANK_CSV)
    scan
    drop('two.csv', BANK_CSV)
    drop('virus.csv', "MZ\x90\x00\x03\x00".b)
    report = scan
    assert_equal 1, report.duplicates
    assert_equal 1, report.quarantined
    quarantined = Dir.children(File.join(@root, @tenant.subdomain, 'quarantine'))
    assert_equal 1, quarantined.size
    assert quarantined.first.end_with?('.quarantined')
    assert_equal 'rejected', Upload.where(origin: 'drop').order(:id).last.status
  end

  test 'links, hard links, fresh files, partial files and hidden files are left alone' do
    outside = File.join(@root, 'secret.csv')
    File.write(outside, BANK_CSV)
    File.symlink(outside, File.join(@incoming, 'link.csv'))
    drop('fresh.csv', BANK_CSV, age: 1)
    drop('half.csv.part', BANK_CSV)
    drop('.hidden.csv', BANK_CSV)
    real = drop('real.csv', UNKNOWN_CSV)
    File.link(real, File.join(@incoming, 'second-name.csv'))
    FileUtils.mkdir(File.join(@incoming, 'folder.csv'))
    report = scan
    assert_equal 0, report.taken
    assert_equal 7, report.skipped
    assert_equal 0, Upload.count
    assert File.exist?(outside)
  end

  test 'an unsafe root or a workspace folder that is a link is refused' do
    drop('a.csv', BANK_CSV)
    File.chmod(0o777, @root)
    assert_match(/real directory/, scan.disabled_reason)
    File.chmod(0o700, @root)
    link = File.join(Dir.mktmpdir('drop-link'), 'root-link')
    File.symlink(@root, link)
    assert_match(/real directory/, Uploads::DropScanner.call(root: link).disabled_reason)
    assert_match(/Disabled/, Uploads::DropScanner.call(root: 'relative/path').disabled_reason)
    assert_equal 0, Upload.count
  end

  test 'a folder for an unknown workspace is ignored' do
    other = File.join(@root, 'not-a-workspace', 'incoming')
    FileUtils.mkdir_p(other, mode: 0o700)
    File.binwrite(File.join(other, 'x.csv'), BANK_CSV).then { File.utime(@old, @old, File.join(other, 'x.csv')) }
    scan
    assert_equal 0, Upload.count
    assert File.exist?(File.join(other, 'x.csv'))
  end
end
