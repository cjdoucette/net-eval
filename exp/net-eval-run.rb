#
# net-eval-run: run experiments on XIA and IP stacks
#
# Author: Cody Doucette <doucette@bu.edu>
#
# This Ruby script runs the next net-eval experiment specified in
# net-eval-status, which is listed in net-eval-tests. It creates the necessary
# containers and network configuration and, if auto-restart was enabled with
# net-eval-setup, restarts the machine and continues the tests.
#


require 'fileutils'
require 'optparse'
require 'io/console'
require './xlxc'


USAGE_STR   = "Usage: ruby net-eval-run.rb"
BOOT_SCRIPT = "/etc/init.d/net-eval"
MTU         = 1500
LOCAL_HID   = "xia0"
# This AD is defined in net-eval/sndpkt.c.
LOCAL_AD    = "000102030405060708090A0B0C0D0E0F00000001"

# net-eval files for the host.
NET_EVAL_EXP    = Dir.pwd
NET_EVAL_TMP    = File.join(NET_EVAL_EXP, "tmp")
NET_EVAL_STATUS = File.join(NET_EVAL_TMP, "net-eval-status")
NET_EVAL_TESTS  = File.join(NET_EVAL_TMP, "net-eval-tests")
NET_EVAL_START  = File.join(NET_EVAL_TMP, "start")
NET_EVAL_LOG    = File.join(NET_EVAL_TMP, "net-eval-log")
NET_EVAL_RUN    = File.join(NET_EVAL_TMP, "running")

# Commands for the host.
RAW_TEST_DATA_CMD = "grep \"#%d#\" --after-context=5 #{NET_EVAL_TESTS}"
XLXC_CREATE_CMD   = "ruby xlxc-create.rb --count=%d%s"
XLXC_DESTROY_CMD  = "ruby xlxc-destroy.rb %s 1 %d"
LXC_EXECUTE_CMD   = "lxc-execute -n %s bash %s.sh"
SHOWNEIGHS_CMD    = "xip hid showneighs"
KILL_CMD          = "killall %s"

# net-eval files for containers.
CONT_NET_EVAL       = "/net-eval"
CONT_NET_EVAL_EXP   = File.join(CONT_NET_EVAL, "exp")
CONT_NET_EVAL_TMP   = File.join(CONT_NET_EVAL_EXP, "tmp")
CONT_NET_EVAL_START = File.join(CONT_NET_EVAL_TMP, "start")
CONT_NET_EVAL_LOGS  = File.join(CONT_NET_EVAL, "logs")
CONT_NET_EVAL_RUN   = File.join(CONT_NET_EVAL_TMP, "running")

# Commands for the containers.
ADD_HID_CMD       = "sudo xip hid add xia%d"
BRIDGE_MAC_ADDR   = "00:00:00:00:00:"
PW_CMD            = "sudo #{File.join(CONT_NET_EVAL, "pw")} --stack=%s " \
                    "--daddr-type=%s --pkt-len=%s --ifname=eth0 "        \
                    "--dmac=#{BRIDGE_MAC_ADDR}%s --zipf=%s --nnodes=%d " \
                    "--run=%s --node-id=%d > %s"


# Output the message and also echo it to the kernel ring buffer.
#
def puts_dmesg(msg)
  puts(msg)
  `echo #{msg} | tee /dev/kmesg`
end

# Parse the command and organize the options.
#
def parse_opts()
  options = {}

  optparse = OptionParser.new do |opts|
    opts.banner = USAGE_STR 
  end

  optparse.parse!
  return options
end

# Redirect the standard error output to the kernel ring buffer.
#
def redirect_stderr()
  $stderr.reopen("/dev/kmesg", "w")
  `dmesg --clear`
end

# Perform error checks on the parameters of the script and options.
#
def check_for_errors(curr_test, last_test)
  # Check that user is root.
  if Process.uid != 0
    puts("net-eval-run must be run as root.")
    exit
  end

  if curr_test < 1 || curr_test > last_test
    puts_dmesg("check net-eval-status: current test " \
               "must be between 1 and last test number.")
    exit
  end
end

# Create containers for the experiment and configure them.
#
def create_containers(isIP, num_port, daddr)

  puts_dmesg("Setting up #{num_port} containers.")

  xlxc_create = sprintf(XLXC_CREATE_CMD, num_port, isIP ? " --ip" : "")
  `#{xlxc_create}`

  # Bind mount net-eval (read-write).
  for i in 1..num_port
    container = File.join(XLXC::LXC, (isIP ? "ip" : "xia") + i.to_s(),
      "rootfs", "net-eval")
    `mkdir -p #{container}`
    `mount --rbind .. #{container}`
  end

  if isIP
    # Disable reverse-path filtering.
    `sysctl -w net.ipv4.conf.default.rp_filter=0`
    `sysctl -w net.ipv4.conf.all.rp_filter=0`

    # Enable IP forwarding.
    `sysctl -w net.ipv4.ip_forward=1`

    # Assign IP address to bridges.
    for i in 1..num_port
      `ifconfig ip#{i}br 192.168.0.#{i + 1 + num_port}/24 up`
    end
  else
    # Load AD and HID principals and add HID for router.
    `modprobe xia_ppal_ad`
    `modprobe xia_ppal_hid`
    `xip hid add #{LOCAL_HID}`

    # If this is testing the via case, add the local AD.
    if daddr == "via"
      `xip ad addlocal #{LOCAL_AD}`
    end
  end
end

# Create scripts to be run by each container.
#
def create_container_scripts(net_eval_exp_path, stack, daddr,
  updates, pkt_len, zipf, num_port, trial_num, exp_name)

  for i in 1..num_port
    # Construct name of script file and log file for container i.
    container_script = File.join(NET_EVAL_TMP, stack + i.to_s() + ".sh")
    pw_log = File.join(CONT_NET_EVAL_LOGS, exp_name, "pw#{i}log")

    # Write the script to the appropriate file for container i.
    # TODO: Output this script in Ruby when Ruby works in containers.
    open(container_script, 'w') { |f|
      if stack == "xia"
        f.puts("sudo xip hid add xia#{i}")
      else
        f.puts("sudo ifconfig eth0 192.168.0.#{i + 1}/24 up")
      end

      f.puts("touch #{File.join(CONT_NET_EVAL_RUN, i.to_s())}")
      f.puts("NUM=`cat #{CONT_NET_EVAL_START}`")
      f.puts("while [ $NUM -ne 1 ]; do")
      f.puts("  NUM=`cat #{CONT_NET_EVAL_START}`")
      f.puts("done")

      f.puts("cd #{CONT_NET_EVAL}")
      f.puts(sprintf(PW_CMD, stack, daddr, pkt_len, "%02x" % i,
        zipf, num_port + 1, trial_num, i, pw_log))
    }
  end
end

# Fork and exec processes for containers.
#
def start_containers(stack, num_port, pkt_len)
  `mkdir -p #{NET_EVAL_RUN}`
  `echo 0 > #{NET_EVAL_START}`

  # Fork and exec containers.
  for i in 1..num_port
    name = stack + i.to_s()
    while !File.exist?(File.join(NET_EVAL_TMP, name + ".sh"))
      sleep(1)
    end
    job = fork do
      exec(sprintf(LXC_EXECUTE_CMD, name, File.join(CONT_NET_EVAL_TMP, name)))
    end
    Process.detach(job)
  end

  # Wait for all containers to start by counting files in NET_EVAL_RUN. 
  while `ls #{NET_EVAL_RUN} | wc -l`.to_i() != num_port
    sleep(1)
    next
  end
  `rm -rf #{NET_EVAL_RUN}`

  # Start packet writers.
  `echo 1 > #{NET_EVAL_START}`

  # Change MTU if necessary.
  if pkt_len > MTU
    increase_mtu(num_port, stack, pkt_len)
  end
end

# Fork and exec processes for pc and rk programs.
#
def run_rk_and_pc(rk_command, pc_command, rk_log)
  job_rk = fork do
    Dir.chdir(File.dirname(NET_EVAL_EXP))
    exec(rk_command)
  end
  Process.detach(job_rk)

  # Allow rk to load.
  while !File.exist?(rk_log) or !File.readlines(rk_log).grep(/DONE/).any?
    sleep(1)
  end

  job_pc = fork do
    Dir.chdir(File.dirname(NET_EVAL_EXP))
    exec(pc_command)
  end
  Process.detach(job_pc)
end

# Make sure NWP has recognized all neighbors.
#
def wait_for_nwp(num_port)
  num_neighs_found = 0
  while num_neighs_found != num_port
    showneighs = `#{SHOWNEIGHS_CMD}`
    num_neighs_found = showneighs.scan(/lladdr/).count()
  end
  puts_dmesg("All containers have been recognized.")
end

# Increase the MTU of all veth connections.
#
def increase_mtu(num_port, stack, pkt_len)
  for i in 1..num_port
    `ifconfig veth.#{i.to_s() + stack} mtu #{pkt_len}`
  end
end

# Stop all rk, pc, and pw programs.
#
def stop_all(updates)
  # Stop rk program if it is still running updates.
  if updates > 0
    `#{sprintf(KILL_CMD, "rk")}`
  end

  # Stop pc program.
  `#{sprintf(KILL_CMD, "pc")}`

  # Stop all packet writers.
  `#{sprintf(KILL_CMD, "pw")}`
end

# Clean up scripts from this experiment and stop containers.
def cleanup_experiment(num_port, stack)
  FileUtils.rm_f(NET_EVAL_START)

  for i in 1..num_port
    # Delete container script.
    FileUtils.rm_f(File.join(NET_EVAL_TMP, stack + i.to_s() + ".sh"))

    if stack == "ip"
      `ifconfig ip#{i}br 192.168.0.#{i + 1 + num_port}/24 down`
    end

    cont = "/var/lib/lxc/#{stack + i.to_s()}/rootfs/net-eval"
    `umount #{cont}`
  end

  # Delete all containers.
  `#{sprintf(XLXC_DESTROY_CMD, stack, num_port)}`
end

# Update the status file for next experiment to be run.
#
def update_status(curr_test, last_test, exp_time, exp_name)
  # Increment experiment number.
  FileUtils.rm_f(NET_EVAL_STATUS)
  open(NET_EVAL_STATUS, 'w') { |f|
    # Increment experiment number.
    f.puts(curr_test + 1)
    f.puts(last_test)
    f.puts(NET_EVAL_EXP)
    f.puts(exp_time)
  }

  if curr_test + 1 > last_test
    FileUtils.rm_f(NET_EVAL_STATUS)
    FileUtils.rm_f(NET_EVAL_TESTS)

    `update-rc.d -f net-eval remove`
    FileUtils.rm_f(BOOT_SCRIPT)
    `update-grub`
  end

  `echo "===================" >> #{NET_EVAL_LOG}`
  `echo "#{exp_name}" >> #{NET_EVAL_LOG}`
  `dmesg --read-clear >> #{NET_EVAL_LOG}`
end


if __FILE__ == $PROGRAM_NAME
  options = parse_opts()

  # Fetch data from status file.
  status = []
  File.open(NET_EVAL_STATUS, 'r').each do |line|
    status.push(line.delete("\n"))
  end
  curr_test = status[0].to_i()
  last_test = status[1].to_i()
  net_eval_exp_path = status[2]
  exp_time = status[3].to_i()

  check_for_errors(curr_test, last_test)

  # Fetch commands and parameters for experiment.
  raw_test_data = `#{sprintf(RAW_TEST_DATA_CMD, curr_test)}`
  test_data = raw_test_data.split("\n")
  pc_command = test_data[1].delete("\n")
  rk_command = test_data[2].delete("\n")
  parameters = test_data[3].split(" ")
  exp_name = test_data[4].delete("\n")
  log_path = test_data[5].delete("\n")

  `mkdir -p #{log_path}`
  rk_log = File.join(log_path, "rklog")
  rk_log_command = sprintf("bash -c \"%s > %s\"", rk_command, rk_log)

  stack = parameters[0]
  daddr = parameters[1]
  updates = parameters[2].to_i()
  pkt_len = parameters[3].to_i()
  zipf = parameters[4].to_f()
  num_port = parameters[5].to_i()
  trial_num = parameters[6].to_i()

  # Create containers and run them. 
  create_containers(stack == "ip", num_port, daddr)
  create_container_scripts(net_eval_exp_path, stack, daddr, updates,
    pkt_len, zipf, num_port, trial_num, exp_name)
  start_containers(stack, num_port, pkt_len)

  if stack == "xia"
    wait_for_nwp(num_port)
  end

  # Run RK and PC and wait.
  run_rk_and_pc(rk_log_command, pc_command, rk_log)
  puts_dmesg("Waiting #{exp_time} seconds for experiment to run.")
  sleep(exp_time)

  # Stop and prepare for next experiment, then reboot.
  stop_all(updates)
  cleanup_experiment(num_port, stack)
  update_status(curr_test, last_test, exp_time, exp_name)
  `shutdown -r now`
end
