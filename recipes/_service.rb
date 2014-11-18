#
# Copyright 2014 John Bellone <jbellone@bloomberg.net>
# Copyright 2014 Bloomberg Finance L.P.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'json'

# Configure directories
consul_directories = []
consul_directories << node['consul']['data_dir']
consul_directories << node['consul']['config_dir']
consul_directories << '/var/lib/consul'

# Select service user & group
case node['consul']['init_style']
when 'runit'
  include_recipe 'runit::default'

  consul_user = node['consul']['service_user']
  consul_group = node['consul']['service_group']
  consul_directories << '/var/log/consul'
else
  consul_user = 'root'
  consul_group = 'root'
end

# Create service user
user "consul service user: #{consul_user}" do
  not_if { consul_user == 'root' }
  username consul_user
  home '/dev/null'
  shell '/bin/false'
  comment 'consul service user'
end

# Create service group
group "consul service group: #{consul_group}" do
  not_if { consul_group == 'root' }
  group_name consul_group
  members consul_user
  append true
end

# Create service directories
consul_directories.each do |dirname|
  directory dirname do
    owner consul_user
    group consul_group
    mode 0755
  end
end

# Determine service params
service_config = JSON.parse(node['consul']['extra_params'].to_json)
service_config['data_dir'] = node['consul']['data_dir']
num_cluster = node['consul']['bootstrap_expect'].to_i

# Determine what join method to specify if not in bootstrap mode
server_join_method_option = 'start_join'
if (node['consul']['join_retry_enabled'])
  server_join_method_option = 'retry_join'
  if (!node['consul']['retry_interval'].nil?)
    service_config['retry_interval'] = node['consul']['retry_interval']
  end
end

case node['consul']['service_mode']
when 'bootstrap'
  service_config['server'] = true
  service_config['bootstrap'] = true
when 'cluster'
  service_config['server'] = true
  if num_cluster > 1
    service_config['bootstrap_expect'] = num_cluster
    service_config[server_join_method_option] = node['consul']['servers']
  else
    service_config['bootstrap'] = true
  end
when 'server'
  service_config['server'] = true
  service_config[server_join_method_option] = node['consul']['servers']
when 'client'
  service_config[server_join_method_option] = node['consul']['servers']
else
  Chef::Application.fatal! %Q(node['consul']['service_mode'] must be "bootstrap", "cluster", "server", or "client")
end

iface_addr_map = {
  :bind_interface => :bind_addr,
  :advertise_interface => :advertise_addr,
  :client_interface => :client_addr
}

iface_addr_map.each_pair do |interface,addr|
  next unless node['consul'][interface]

  if node["network"]["interfaces"][node['consul'][interface]]
    ip = node["network"]["interfaces"][node['consul'][interface]]["addresses"].detect{|k,v| v[:family] == "inet"}.first
    node.default['consul'][addr] = ip
  else
    Chef::Application.fatal!("Interface specified in node['consul'][#{interface}] does not exist!")
  end
end

if node['consul']['serve_ui']
  service_config['ui_dir'] = node['consul']['ui_dir']
  service_config['client_addr'] = node['consul']['client_addr']
end

copy_params = [
  :bind_addr, :datacenter, :domain, :log_level, :node_name, :advertise_addr, :ports, :enable_syslog
]
copy_params.each do |key|
  if node['consul'][key]
    if key == :ports
      Chef::Application.fatal! 'node[:consul][:ports] must be a Hash' unless node[:consul][key].kind_of?(Hash)
    end

    service_config[key] = node['consul'][key]
  end
end

dbi = nil
# Gossip encryption
if node.consul.encrypt_enabled
  # Fetch the databag only once, and use empty hash if it doesn't exists
  dbi = consul_encrypted_dbi || {}
  secret = consul_dbi_key_with_node_default(dbi, 'encrypt')
  raise "Consul encrypt key is empty or nil" if secret.nil? or secret.empty?
  service_config['encrypt'] = secret
else
  # for backward compatibilty
  service_config['encrypt'] = node.consul.encrypt unless node.consul.encrypt.nil?
end

# TLS encryption
if node.consul.verify_incoming || node.consul.verify_outgoing
  dbi = consul_encrypted_dbi || {} if dbi.nil?
  service_config['verify_outgoing'] = node.consul.verify_outgoing
  service_config['verify_incoming'] = node.consul.verify_incoming

  ca_path = node.consul.ca_path % { config_dir: node.consul.config_dir }
  service_config['ca_file'] = ca_path

  cert_path = node.consul.cert_path % { config_dir: node.consul.config_dir }
  service_config['cert_file'] = cert_path

  key_path = node.consul.key_file_path % { config_dir: node.consul.config_dir }
  service_config['key_file'] = key_path

  # Search for key_file_hostname since key and cert file can be unique/host
  key_content = dbi['key_file_' + node.fqdn] || consul_dbi_key_with_node_default(dbi, 'key_file')
  cert_content = dbi['cert_file_' + node.fqdn] || consul_dbi_key_with_node_default(dbi, 'cert_file')
  ca_content = consul_dbi_key_with_node_default(dbi, 'ca_cert')

  # Save the certs if exists
  {ca_path => ca_content, key_path => key_content, cert_path => cert_content}.each do |path, content|
    unless content.nil? or content.empty?
      file path do
        user consul_user
        group consul_group
        mode 0600
        action :create
        content content
      end
    end
  end
end

consul_config_filename = File.join(node['consul']['config_dir'], 'default.json')

file consul_config_filename do
  user consul_user
  group consul_group
  mode 0600
  action :create
  content JSON.pretty_generate(service_config, quirks_mode: true)
  # https://github.com/johnbellone/consul-cookbook/issues/72
  notifies :restart, "service[consul]"
end

case node['consul']['init_style']
when 'init'
  if platform?("ubuntu")
    init_file = '/etc/init/consul.conf'
    init_tmpl = 'consul.conf.erb'
  else
    init_file = '/etc/init.d/consul'
    init_tmpl = 'consul-init.erb'
  end

  template node['consul']['etc_config_dir'] do
    source 'consul-sysconfig.erb'
    mode 0755
    notifies :create, "template[#{init_file}]", :immediately
  end

  template init_file do
    source init_tmpl
    mode 0755
    variables(
      consul_binary: "#{node['consul']['install_dir']}/consul",
      config_dir: node['consul']['config_dir'],
    )
    notifies :restart, 'service[consul]', :immediately
  end

  service 'consul' do
    provider Chef::Provider::Service::Upstart if platform?("ubuntu")
    supports status: true, restart: true, reload: true
    action [:enable, :start]
    subscribes :restart, "file[#{consul_config_filename}", :delayed
  end
when 'runit'
  runit_service 'consul' do
    supports status: true, restart: true, reload: true
    action [:enable, :start]
    subscribes :restart, "file[#{consul_config_filename}]", :delayed
    log true
    options(
      consul_binary: "#{node['consul']['install_dir']}/consul",
      config_dir: node['consul']['config_dir'],
    )
  end
end
