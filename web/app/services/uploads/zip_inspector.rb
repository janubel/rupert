# frozen_string_literal: true

require 'zlib'

module Uploads
  # Reads an .xlsx container's table of contents without inflating anything, so a
  # zip bomb is refused by arithmetic on the declared sizes, and inflates single
  # parts only under a hard output cap. Nothing is extracted to disk.
  class ZipInspector
    Error = Class.new(StandardError)
    Entry = Struct.new(:name, :method, :compressed, :uncompressed, :offset, keyword_init: true)

    EOCD_SIGNATURE = "PK\x05\x06".b
    CENTRAL_SIGNATURE = "PK\x01\x02".b
    LOCAL_SIGNATURE = "PK\x03\x04".b

    attr_reader :entries

    def initialize(bytes)
      @bytes = bytes.b
      @entries = read_directory
      check_sizes!
    end

    def entry(name)
      @entries.find { |candidate| candidate.name == name }
    end

    def read(name, max: Limits::ZIP_PART_READ)
      found = entry(name) or return nil
      raise Error, "#{name} is too large to read safely." if found.uncompressed > max

      start = data_offset(found)
      raw = @bytes.byteslice(start, found.compressed)
      raise Error, 'The archive is truncated.' unless raw && raw.bytesize == found.compressed

      found.method.zero? ? raw : inflate(raw, found.uncompressed)
    end

    private

    def read_directory
      tail_start = [@bytes.bytesize - 65_557, 0].max
      tail = @bytes.byteslice(tail_start, @bytes.bytesize - tail_start)
      at = tail.rindex(EOCD_SIGNATURE) or raise Error, 'Not a valid Excel workbook (no zip directory).'
      disk, dir_disk, _here, total, size, offset = tail.byteslice(at + 4, 18).unpack('vvvvVV')
      raise Error, 'Multi-part archives are not supported.' unless disk.zero? && dir_disk.zero?
      raise Error, 'The workbook has too many parts.' if total > Limits::ZIP_MAX_ENTRIES
      raise Error, 'Large (zip64) archives are not supported.' if [size, offset].include?(0xFFFFFFFF) || total == 0xFFFF
      raise Error, 'The archive directory is out of bounds.' if offset + size > @bytes.bytesize

      cursor = offset
      Array.new(total) do
        header = @bytes.byteslice(cursor, 46)
        raise Error, 'The archive directory is damaged.' unless header && header.bytesize == 46 && header.start_with?(CENTRAL_SIGNATURE)

        _made, _need, flags, method, _time, _date, _crc, compressed, uncompressed, name_len, extra_len, comment_len, _disk, _int, _ext, local =
          header.byteslice(4, 42).unpack('vvvvvvVVVvvvvvVV')
        raise Error, 'Encrypted workbooks are not supported.' if flags.anybits?(0x1)
        raise Error, 'The workbook uses an unsupported compression method.' unless [0, 8].include?(method)
        raise Error, 'Large (zip64) archives are not supported.' if [compressed, uncompressed, local].include?(0xFFFFFFFF)

        name = @bytes.byteslice(cursor + 46, name_len).to_s.force_encoding(Encoding::UTF_8)
        raise Error, 'A part has an unsafe name.' unless name.valid_encoding? && safe_name?(name)

        cursor += 46 + name_len + extra_len + comment_len
        Entry.new(name: name, method: method, compressed: compressed, uncompressed: uncompressed, offset: local)
      end
    end

    def safe_name?(name)
      !name.empty? && !name.start_with?('/') && !name.include?("\x00") && name.split('/').none? { |part| part == '..' } && !name.include?('\\')
    end

    def check_sizes!
      total = @entries.sum(&:uncompressed)
      raise Error, 'The workbook expands to more than 100 MiB, so it was not accepted.' if total > Limits::ZIP_MAX_UNCOMPRESSED
      raise Error, 'The workbook is compressed far more than a real spreadsheet, so it was not accepted.' if total > 1_048_576 && total > @bytes.bytesize * Limits::ZIP_MAX_RATIO

      @entries.each do |part|
        next unless part.uncompressed > 1_048_576 && part.compressed.positive? && part.uncompressed / part.compressed > Limits::ZIP_MAX_RATIO

        raise Error, 'A part of the workbook is compressed far more than a real spreadsheet, so it was not accepted.'
      end
    end

    def data_offset(found)
      header = @bytes.byteslice(found.offset, 30)
      raise Error, 'The archive is damaged.' unless header && header.bytesize == 30 && header.start_with?(LOCAL_SIGNATURE)

      name_len, extra_len = header.byteslice(26, 4).unpack('vv')
      found.offset + 30 + name_len + extra_len
    end

    def inflate(raw, expected)
      inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
      out = String.new(encoding: Encoding::BINARY)
      grow = lambda do |piece|
        out << piece
        raise Error, 'A part inflated beyond its declared size.' if out.bytesize > expected
      end
      offset = 0
      while offset < raw.bytesize
        # Block form yields pieces as they are produced, so the cap is enforced
        # before a hostile chunk can expand in memory.
        inflater.inflate(raw.byteslice(offset, 16_384), &grow)
        offset += 16_384
      end
      inflater.finish.then { |rest| grow.call(rest) unless rest.empty? }
      out
    rescue Zlib::Error
      raise Error, 'A part of the workbook is damaged.'
    ensure
      inflater&.close
    end
  end
end
