# frozen_string_literal: true

require 'test_helper'

class HostVitalsTest < ActiveSupport::TestCase
  test 'reads load, memory, disk and database size from this host' do
    reading = HostVitals.read
    assert_kind_of Integer, reading.cpu
    assert reading.memory.between?(0, 100)
    assert reading.disk.between?(0, 100)
    assert reading.db_bytes.positive?
  end

  test 'CPU is this container\'s own CPU time, not the host load average' do
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Rails.cache.write(HostVitals::CPU_SAMPLE_KEY, [now - 10, 1_000_000])
    cores = Etc.nprocessors
    # Half of every core for the last 10 seconds.
    HostVitals.stub(:cgroup_cpu_usec, 1_000_000 + (cores * 5_000_000)) do
      HostVitals.stub(:load_percent, 100) do
        assert_in_delta 50, HostVitals.send(:cpu_percent), 1
      end
    end
  ensure
    Rails.cache = previous_cache
  end

  test 'without a cgroup, CPU falls back to the load average' do
    HostVitals.stub(:cgroup_cpu_usec, nil) do
      HostVitals.stub(:load_percent, 42) { assert_equal 42, HostVitals.send(:cpu_percent) }
    end
  end

  test 'thresholds turn amber at 80 and red at 90' do
    assert_equal 'pill-fern', HostVitals.tone(10)
    assert_equal 'pill-clay', HostVitals.tone(80)
    assert_equal 'pill-rose', HostVitals.tone(95)
    assert_equal 'pill-taupe', HostVitals.tone(nil)
  end

  test 'the last good backup size comes from the backup log' do
    BackupLog.unscoped.create!(id: SecureRandom.uuid, tenant_id: nil, status: 'success', startedAt: 2.hours.ago, finishedAt: 2.hours.ago, fileSize: 5_000_000)
    reading = HostVitals.read
    assert_equal 5_000_000, reading.backup_bytes
  end
end
