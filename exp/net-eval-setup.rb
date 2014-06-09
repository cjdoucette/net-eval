#
# net-eval-setup: setup experiments on XIA and IP stacks
#
# Author: Cody Doucette <doucette@bu.edu>
#
# This Ruby script sets up a series of experiments which measure the packet
# forwarding abilities of the IP stack and XIA stack. The user of the script
# can choose one or more independent variables for the experiments. To carry
# out the experiments, this script also creates temporary files named
# net-eval-tests and net-eval-status.
#


require 'fileutils'
require 'optparse'


# Ranges of independent variables.
ZIPFS     = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0,
             1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0]
SIZES     = [64, 128, 256, 512, 1024, 2048]
UPDATES   = [0, 10 ** 0, 10 ** 1, 10 ** 2, 10 ** 3, 10 ** 4, 10 ** 5] 
DADDRS    = ["ip", "fb0", "fb1", "fb2", "fb3", "via"]
MAX_PORTS = 32

# Default values for independent variables.
DEF_ZIPF      = 1.0
DEF_SIZE      = 256
DEF_UPD       = 0
DEF_XIA_DADDR = "fb0"
DEF_IP_DADDR  = "ip"
DEF_PORTS     = 4

# Pathnames for net-eval files.
NET_EVAL        = File.dirname(Dir.pwd)
NET_EVAL_EXP    = Dir.pwd
NET_EVAL_TMP    = File.join(NET_EVAL_EXP, "tmp")
NET_EVAL_TESTS  = File.join(NET_EVAL_TMP, "net-eval-tests")
NET_EVAL_STATUS = File.join(NET_EVAL_TMP, "net-eval-status")
NET_EVAL_LOGS   = File.join(NET_EVAL, "logs")
NET_EVAL_PC     = File.join(NET_EVAL, "pc")
NET_EVAL_RK     = File.join(NET_EVAL, "rk")

# Pathnames for files not stored within net-eval.
XIP                  = "/sbin/xip"
HIDS                 = "/etc/xia/hid/prv"
BOOT_SCRIPT          = "/etc/init.d/net-eval"
BOOT_SCRIPT_TEMPLATE = File.join(NET_EVAL_EXP, "boot")

USAGE_STR = "Usage: ruby net-eval-setup.rb -d | NUM_TRIALS EXP_TIME [OPTIONS]"

# Parse the command and organize the options.
#
def parse_opts()
  options = {}

  optparse = OptionParser.new do |opts|

    opts.banner = USAGE_STR 

    options[:enable] = false
    opts.on('-e', '--enable', 'Enable boot script testing') do
      options[:enable] = true
    end

    options[:disable] = false
    opts.on('-d', '--disable', 'Disable boot script testing and exit') do
      options[:disable] = true
    end

    options[:daddr] = false
    opts.on('-a', '--addr', 'Test changing address type') do
      options[:daddr] = true
    end

    options[:ports] = false
    opts.on('-p', '--ports', 'Test changing number of ports') do
      options[:ports] = true
    end

    options[:size] = false
    opts.on('-s', '--size', 'Test changing packet size') do
      options[:size] = true
    end

    options[:upd] = false
    opts.on('-u', '--updates', 'Test changing routing table update rate') do
      options[:upd] = true
    end

    options[:zipf] = false
    opts.on('-z', '--zipf', 'Test changing the zipf distribution') do
      options[:zipf] = true
    end

    options[:ip] = false
    opts.on('-i', '--ip', 'Perform experiments on IP stack') do
      options[:ip] = true
    end

    options[:xia] = false
    opts.on('-x', '--xia', 'Perform experiments on XIA stack') do
      options[:xia] = true
    end
  end

  optparse.parse!
  return options
end

# Deletes any net-eval boot script that may be present.
#
def disable_boot_script()
    `update-rc.d -f net-eval remove`
    `update-grub`
    FileUtils.rm_f(BOOT_SCRIPT)
end

# Perform error checks on the parameters of the script and options.
#
def check_for_errors(options)
  # Check that all arguments are present.
  if ARGV.length != 2
    puts("Specify NUM_TRIALS and EXP_TIME and then any options.")
    puts(USAGE_STR)
    exit
  end

  # Check that at least one stack is specified.
  if !options[:xia] && !options[:ip]
    puts("Specify network to use (-x for XIA; -i for IP).")
    exit
  end

  # Make sure xip application is installed.
  if !File.exists?(XIP)
    puts("xip application missing; download and install xip.")
    exit
  end

  # Make sure at least one test is specified.
  if !options[:ports] && !options[:zipf] && !options[:upd] &&
     !options[:daddr] && !options[:size]
    puts("Specify at least one test to run.")
    exit
  end
end

# Creates a boot script to enable large-scale experiments.
#
def enable_boot_script()
  # Copy boot script template to system's boot script directory.
  FileUtils.cp(BOOT_SCRIPT_TEMPLATE, BOOT_SCRIPT)

  # Append to boot script to work with current settings.
  open(BOOT_SCRIPT, 'a') { |f|
    f.puts("Dir.chdir(\"#{NET_EVAL_EXP}\")")
    f.puts("`ruby net-eval-run.rb`")
  }

  # Enable boot script at runlevel 2.
  `chmod 755 #{BOOT_SCRIPT}`
  `update-rc.d net-eval start 99 2 .`
  `update-grub`
end

# Make sure all necessary HIDs have been created.
#
def create_hids(num_ports)
  for i in 0..num_ports
    if !File.exists?(File.join(HIDS, "xia#{i}"))
      `xip hid new xia#{i}`
    end
  end
end

# Make HIDs readily available for experiments.
#
def fetch_hids(num_ports)
  create_hids(num_ports)

  print("Fetching HIDs... ")
  hids = []
  for i in 1..num_ports
    hid = `xip hid getpub xia#{i} | grep hid`
    hids.push(`echo "#{hid}" | awk -F- ' { print $2 } '`.delete("\n"))
  end
  puts("done.")

  return hids
end

# Initialize temporary files used by experiments.
#
def init_temp_files()
  if !Dir.exists?(NET_EVAL_TMP)
    Dir.mkdir(NET_EVAL_TMP)
  end

  FileUtils.rm_f(NET_EVAL_TESTS)
  FileUtils.touch(NET_EVAL_TESTS)
end

# Sets up an experiment with the given parameters.
#
def setup_exp(exp_num, name, column, trial_num, stack, hids,
              daddr, updates, pkt_len, zipf, num_port)

  exp_name = sprintf("exp-%s/%s/%s/run%s", name, stack, column, trial_num)
  parameters = sprintf("%s %s %s %s %s %s %s", stack, daddr, updates,
    pkt_len, zipf, num_port, trial_num)
  pc_command = sprintf("%s --stack=%s --daemon --add-rules --parents " \
                       "--file=%s", NET_EVAL_PC, stack, exp_name)
  rk_command = sprintf("%s --run=%s --stack=%s --upd-rate=%s",
    NET_EVAL_RK, trial_num, stack, updates)

  # Add a veth for every port to the pc command, and
  # add an address for every port to the rk command.
  for i in 1..num_port
    pc_command += sprintf(" veth.%i%s", i, stack)

    id = (stack == "xia") ? hids[i - 1] : "192.168.0.#{i + 1}"
    rk_command += sprintf(" %s%ibr %s", stack, i, id)
  end

  # Append experiment number, pc and rk commands,
  # parameters and experiment name to tests file.
  open(NET_EVAL_TESTS, 'a') { |f|
    f.puts("##{exp_num}#\n" +
           pc_command + "\n" +
           rk_command + "\n" +
           parameters + "\n" +
           exp_name   + "\n" +
           File.join(NET_EVAL_LOGS, exp_name))
  }
end

# Independent variable: number of ports.
#
def num_port(exp_num, num_trials, stacks, hids, ports)
  for stack in stacks
    daddr = (stack == "xia") ? DEF_XIA_DADDR : DEF_IP_DADDR
    for num_ports in ports
      for trial in 1..num_trials
        setup_exp(exp_num, "num-port", num_ports, trial, stack, hids,
          daddr, DEF_UPD, DEF_SIZE, DEF_ZIPF, num_ports)
        exp_num += 1
      end
    end
  end
  return exp_num
end

# Independent variable: zipf distribution parameter.
#
def zipf(exp_num, num_trials, stacks, hids)
  for stack in stacks
    daddr = (stack == "xia") ? DEF_XIA_DADDR : DEF_IP_DADDR
    for zipf in ZIPFS
      for trial in 1..num_trials
        setup_exp(exp_num, "zipf", zipf, trial, stack, hids,
          daddr, DEF_UPD, DEF_SIZE, zipf, DEF_PORTS)
        exp_num += 1
      end
    end
  end
  return exp_num
end

# Independent variable: update rate.
#
def updates(exp_num, num_trials, stacks, hids, options)
  for upd in UPDATES
    for daddr in DADDRS

      # Skip since IP cannot handle 10 ** 5 updates.
      if (upd == 10 ** 5) && daddr == "ip"
        next
      # Skip if stack and daddr don't match.
      elsif options[:ip] && !options[:xia] && daddr != "ip"
        next
      elsif !options[:ip] && options[:xia] && daddr == "ip"
        next
      end

      stack = (daddr == "ip") ? "ip" : "xia"
      for trial in 1..num_trials
        setup_exp(exp_num, "updates", daddr + "/" + upd.to_s(), trial, stack,
                  hids, daddr, upd, DEF_SIZE, DEF_ZIPF, DEF_PORTS)
        exp_num += 1
      end
    end
  end
  return exp_num
end

# Independent variable: packet size.
#
def pkt_len(exp_num, num_trials, stacks, hids)
  for stack in stacks
    daddr = (stack == "xia") ? DEF_XIA_DADDR : DEF_IP_DADDR
    for size in SIZES
      for trial in 1..num_trials
        setup_exp(exp_num, "pkt-len", size, trial, stack, hids,
          daddr, DEF_UPD, size, DEF_ZIPF, DEF_PORTS)
        exp_num += 1
      end
    end
  end
  return exp_num
end

# Independent variable: type of destination address/packet size.
#
def daddr(exp_num, num_trials, stacks, hids, options)
  for size in SIZES
    for daddr in DADDRS

      # Skip if stack and daddr don't match.
      if options[:ip] && !options[:xia] && daddr != "ip"
        next
      elsif !options[:ip] && options[:xia] && daddr == "ip"
        next
      # Skip 64 byte packets for fb1, fb2, fb3 and via.
      elsif size == 64 && daddr != "ip" && daddr != "fb0"
        next
      # Skip 128 byte packets for fb3.
      elsif size == 128 && daddr == "fb3"
        next
      end

      stack = (daddr == "ip") ? "ip" : "xia"
      for trial in 1..num_trials
        setup_exp(exp_num, "daddr", daddr + "/" + size.to_s(), trial, stack,
          hids, daddr, DEF_UPD, size, DEF_ZIPF, DEF_PORTS)
        exp_num += 1
      end
    end
  end
  return exp_num
end

# Create file to help keep track of current state of experiments.
#
def create_status_file(exp_num, exp_time)
  FileUtils.rm_f(NET_EVAL_STATUS)
  open(NET_EVAL_STATUS, 'w') { |f|
    f.puts(1)
    f.puts(exp_num - 1)
    f.puts(NET_EVAL_EXP)
    f.puts(exp_time)
  }
end


if __FILE__ == $PROGRAM_NAME
  options = parse_opts()

  # Check that user is root.
  if Process.uid != 0
    puts("net-eval-setup must be run as root.")
    exit
  end

  if options[:disable]
    disable_boot_script()
    exit
  end

  check_for_errors(options)

  if options[:enable]
    enable_boot_script()
  end

  num_trials = ARGV[0].to_i()
  exp_time = ARGV[1].to_i()
  num_ports = options[:ports] ? MAX_PORTS : DEF_PORTS
  ports = Array(1..num_ports)

  stacks = []
  hids = []
  if options[:xia]
    stacks.push("xia")
    hids = fetch_hids(num_ports)
  end
  if options[:ip]
    stacks.push("ip")
  end

  init_temp_files()

  exp_num = 1
  print("Setting up tests... ")

  if options[:ports]
    exp_num = num_port(exp_num, num_trials, stacks, hids, ports)
  end

  if options[:zipf]
    exp_num = zipf(exp_num, num_trials, stacks, hids)
  end

  if options[:upd]
    exp_num = updates(exp_num, num_trials, stacks, hids, options)
  end
  
  if options[:size]
    exp_num = pkt_len(exp_num, num_trials, stacks, hids)
  end

  if options[:daddr]
    exp_num = daddr(exp_num, num_trials, stacks, hids, options)
  end

  create_status_file(exp_num, exp_time)
  puts("done.")
end
