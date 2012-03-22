require 'version'
require 'instruction'
require 'helpers'
require 'nokogiri'

module ECUTools
  class Disassembler
    include ECUTools::Helpers

    def initialize(input = nil, options = {})
      @options = options
      @table_addresses = {}
      @scale_addresses = {}
      if(!input.nil?)
        open input
      end
    end

    def verbose
      @options[:verbose]
    end

    def open(file)
      $stderr.puts "Disassembling binary..." if verbose
      h = '[\d|[a-f]|[A-F]]'
      @assembly = []
      io = IO.popen("gobjdump -b binary --architecture=m32r --disassemble-all --disassemble-zeroes -EB #{file}")
      while line = io.gets
        match = /\s+(#{h}+):\s+(#{h}{2}) (#{h}{2}) (#{h}{2}) (#{h}{2})\s+(.+)/.match(line)
        if match
          @assembly << Instruction.new(match[1], [ match[2], match[3], match[4], match[5] ], match[6])
        end
      end

      $stderr.puts "Disassembly complete." if verbose
    end

    def write(file)
      f = File.new(file,"w")
      header = "; ecutools v#{ECUTools::VERSION}\n"
      header << "; Generated assembly from ROM ID #{rom_id}\n"
      header << "; Base Address: #{base_address}\n"
      header << "; Disassembly:\n"
      f.write(header)
      $stderr.puts "Writing assembly..." if verbose
      @assembly.each do |instruction|
        f.write("#{instruction}\n")
      end
      $stderr.puts "Done." if verbose
    end

    def analyze
      $stderr.puts "Analyzing assembly..." if verbose
      annotate_scales
      annotate_tables
      annotate_code
      $stderr.puts "Analyzation complete." if verbose
    end

    def annotate_scales
      $stderr.puts "Annotating scales..." if verbose
      scales = rom_xml.xpath('/rom/table/table')
      count = 0
      injected_scales = []
      scales.each do |scale|
        next if scale.attr('address').nil? # skip scales without an address, they won't be in the ROM!
        next if injected_scales.include? scale.attr('address')
        injected_scales << scale.attr('address')

        elements = scale.attr('elements').to_i
        scaling = rom_xml.xpath("/rom/scaling[@name='#{scale.attr('scaling')}']")
        if scaling.count == 0
          $stderr.puts "WARNING: Failed to find scaling: #{scale.attr('scaling')}, skipping scale #{scale.attr('name')}" if verbose
          next
        end
        element_size = scaling.attr('storagetype').value().gsub(/[^\d]+/,'').to_i / 8
        storage_size = element_size * elements
        scale_label = "#{scale.attr('name')}, #{elements} elements"
        address = from_hex scale.attr('address')

        possible_offsets = [ 2,6 ]

        # read in the header of the scale, could fail for "headless" scales but that's ok
        header = read_scale_header(address - 6)
        if header[:entries] != elements  and verbose
          $stderr.puts "Header/XML Mismatch for Scale #{scale.attr('name')} @ #{scale.attr('address')}. XML: #{elements}, Header: #{header[:entries]}. Could be bad XML or a headless scale." if verbose
        else
          src_label = address_descriptions[header[:src]].nil? ? nil : " (#{address_descriptions[header[:src]]})"
          dest_label = address_descriptions[header[:dest]].nil? ? nil : " (#{address_descriptions[header[:dest]]})"
          scale_label << ", S = 0x#{header[:src]}#{src_label}, D = 0x#{header[:dest]}#{dest_label}"
        end

        possible_offsets.each do |offset|
          offset_hex = (address - offset).to_s(16)
          @scale_addresses[offset_hex] = scale_label if !@scale_addresses.include? offset_hex
        end

        storage_size.times do |n|
          instruction = instruction_at(address + n)
          instruction.data = true
          instruction.comment(address + n, "Scale #{scale_label}, 0x#{scale.attr('address')} -> 0x#{(address + storage_size - 1).to_s(16)}")
        end

        count = count + 1
      end
      $stderr.puts "#{count} scales annotated." if verbose
    end

    def annotate_tables
      $stderr.puts "Annotating tables..." if verbose
      tables = rom_xml.xpath('/rom/table')
      count = 0
      tables.each do |table|
        next if table.attr('address').nil? # skip scales without an address, they won't be in the ROM!
        
        elements = 1 # all tables start with one element
        is_data = false
        header = nil
        possible_offsets = []
        
        scaling = rom_xml.xpath("/rom/scaling[@name='#{table.attr('scaling')}']")
        if scaling.count == 0
          $stderr.puts "WARNING: Failed to find scaling: #{table.attr('scaling')}, skipping table #{table.attr('name')}" if verbose
          next
        end

        table.xpath('table').each do |subtable|
          elements = elements * subtable.attr('elements').to_i
          is_data = true
        end
        address = from_hex table.attr('address')
        element_size = scaling.attr('storagetype').value().gsub(/[^\d]+/,'').to_i / 8
        
        if elements == 1 
          possible_offsets << 0 # straight values
        else
          case element_size
          when 1
            case table.attr('type')
            when "2D"
              possible_offsets << 4 # 8bit 2D
              header = read_8bit_header(address - 4)
            when "3D"
              possible_offsets << 7 # 8bit 3D
              possible_offsets << 8 # oddball tables, 8bit 3D, attached to headless scales
              header = read_8bit_header(address - 7)
            else
              $stderr.puts "ERROR: Bad table definition for #{table.attr('name')}, not 2D or 3D, skipping table."
              next
            end
          when 2
            case table.attr('type')
            when "2D"
              possible_offsets << 6 # 16bit 2D
              header = read_16bit_header(address - 6)
            when "3D"
              possible_offsets << 10 # 16bit 3D
              header = read_16bit_header(address - 10)
            else
              $stderr.puts "ERROR: Bad table definition for #{table.attr('name')}, not 2D or 3D, skipping table."
              next
            end
          else
            $stderr.puts "ERROR: Bad table definition for #{table.attr('name')}, not 8bit or 16bit, skipping table."
            next
          end
        end
        
        if header.nil?
          table_label = "#{table.attr('name')} (#{elements} elements, headless)"
        else
          table_label = "#{table.attr('name')} (#{elements} elements, X = 0x#{header[:x_address]}, Y = #{header[:y_address]})"
        end
      
        possible_offsets.each do |offset|
          offset_hex = (address - offset).to_s(16)
          @table_addresses[offset_hex] = table_label if !@table_addresses.include? offset_hex
        end

        storage_size = element_size * elements

        storage_size.times do |n|
          instruction = instruction_at(address + n)
          instruction.data = is_data
          instruction.comment(address + n, table.attr('name') + "(0x#{table.attr('address')} -> 0x#{(address + storage_size - 1).to_s(16)}, #{storage_size} bytes, #{elements} values)")
        end

        count = count + 1
      end
      $stderr.puts "#{count} tables annotated." if verbose
    end

    def annotate_code
      $stderr.puts "Annotating code..." if verbose
      count = 0
      unknown_scale_count = 0
      injected_scales = []
      found_rom_addresses = {}
      found_ram_addresses = {}
      @assembly.each do |instruction|
        # annotate subroute prologue/epilogue
        if instruction.assembly =~ /jmp lr/ 
          instruction.comment instruction.address, 'return'
          next_instruction = instruction_at instruction.address.to_i(16) + 4
          next_instruction.comment next_instruction.address, 'likely subroutine address'
        end
        
        if subroutine_descriptions.include? instruction.address
          instruction.comment instruction.address, "begin subroutine #{subroutine_descriptions[instruction.address]}" 
        end
        
        subroutine_descriptions

        # annotate subroutine calls
        match = /bl 0x(\w+)/.match(instruction.assembly)
        if match
          address = match[1]
          if subroutine_descriptions.include? address
            instruction.comment instruction.address.to_i(16) + 2, "Call #{subroutine_descriptions[address]}"
          end
        end 

        # annotate table address references
        address = /0x([\d|[a-f]|[A-F]]+)/.match(instruction.assembly)
        if address and @table_addresses.include? address[1]
          instruction.comment instruction.address, "Get table #{@table_addresses[address[1]]}"
          count = count + 1
          found_rom_addresses[@table_addresses[address[1]]] = true 
        end

        # annotate scale address references
        if address and @scale_addresses.include? address[1]
          instruction.comment instruction.address, "Get scale #{@scale_addresses[address[1]]}"
          count = count + 1
        end

        # annotate absolute RAM addressing
        match = /(\w+)\s+\w\w,0x(8\w\w\w\w\w)/.match(instruction.assembly)
        if match
          address = match[2]
          display = address_descriptions[address]

          if match[1] == "ld24"
            op = "Assign pointer to"
          else
            op = "Unknown op on"
          end

          instruction.comment instruction.address, "#{op} RAM address 0x#{address}" + (display.nil? ? '' : " (#{display})")
          found_ram_addresses[display] = true if !display.nil?
          count = count + 1
        end

        # annotate relative RAM addressing
        match = /(\w+)\s+.+?@\((-?\d+),fp\)/.match(instruction.assembly)
        if match
          address = absolute_address match[2].to_i
          display = address_descriptions[address]

          case match[1]
          when "lduh"
            op = "Load unsigned halfword from"
          when "ldub"
            op = "Load unsigned byte from"
          when "ld"
            op = "Load from"
          when "ldb"
            op = "Load byte from"
          when "st" 
            op = "Store at"
          when "stb"
            op = "Store byte at"
          when "sth"
            op = "Store half word at"
          when "bclr"
            op = "Clear bit in"
          else
            op = "Unknown op on"
          end
          instruction.comment instruction.address, "#{op} RAM address 0x#{address}" + (display.nil? ? '' : " (#{display})")
          found_ram_addresses[display] = true if !display.nil?
          count = count + 1
        end
        
        # annotate scales
        # ld24 r0,0x5f51a
        match = /ld24 r0,0x(\w{1,5})/.match(instruction.assembly)
        if match and match[1].to_i(16) > "0x40000".to_i(16) and instruction.comments.length == 0 and !injected_scales.include?(match[1])
          address = match[1].to_i(16)
          header = read_scale_header(address)
          if header[:dest] =~ /8\w\w\w\w\w/ && header[:src] =~ /8\w\w\w\w\w/ && header[:entries] < 100
            injected_scales << match[1]
            # we have a valid scale header
            unknown_scale_count = unknown_scale_count + 1
            src_label = address_descriptions[header[:src]].nil? ? nil : " (#{address_descriptions[header[:src]]})"
            dest_label = address_descriptions[header[:dest]].nil? ? nil : " (#{address_descriptions[header[:dest]]})"
            elements = header[:entries]
            instruction.comment instruction.address, "Reference to unknown scale: #{elements} elements, S = #{header[:src]}#{src_label}, D = #{header[:dest]}#{dest_label}"
            #scale_inst = instruction_at address + 6
            puts "<table name=\"Unknown Scale \##{unknown_scale_count}#{src_label}\" address=\"#{(address + 6).to_s(16)}\" type=\"Y Axis\" elements=\"#{elements}\" scaling=\"uint16\"/>"
          end
        end
      end

      $stderr.puts "#{count} lines of code annotated." if verbose
      if verbose
        @table_addresses.each_key do |key|
          $stderr.puts "Unable to find any reference to table #{@table_addresses[key]}" if !found_rom_addresses.include? @table_addresses[key]
          found_rom_addresses[@table_addresses[key]] = true # stop multiple reports
        end
      end
    end

  end
end