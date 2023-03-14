# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.define "Wordpress" do |wordpress|
    wordpress.vm.box = "ubuntu/jammy64"
    wordpress.vm.box_check_update = false
    wordpress.vm.hostname = "Wordpress"
    wordpress.vm.provider "virtualbox" do |vb|
      vb.name = "ubuntu_wordpress"
      vb.memory = "1024"
      vb.cpus = "1"
      vb.default_nic_type = "virtio"
      file_to_disk = "disk_MariaDB.vmdk"
      unless File.exist?(file_to_disk)
        vb.customize [ "createmedium", "disk", "--filename", file_to_disk, "--format", "vmdk", "--size", 2048 * 1 ]
      end
      vb.customize [ "storageattach", "ubuntu_wordpress" , "--storagectl", "SCSI", "--port", "2", "--device", "0", "--type", "hdd", "--medium", file_to_disk]
    end
    wordpress.vm.network "private_network", ip: "192.168.1.50", nic_type: "virtio", virtualbox__intnet: "sysadmin"
    wordpress.vm.network "forwarded_port", guest: 80, host: 8080
    wordpress.vm.provision "shell", path: "provision_wp.sh"
  end
  
  config.vm.define "Elasticsearch" do |elasticsearch|
    elasticsearch.vm.box = "ubuntu/jammy64"
    elasticsearch.vm.box_check_update = false
    elasticsearch.vm.hostname = "Elasticsearch"
    elasticsearch.vm.provider "virtualbox" do |vb|
      vb.name = "ubuntu_ELK"
      vb.memory = "4096"
      vb.cpus = "1"
      vb.default_nic_type = "virtio"
      file_to_disk = "disk_elasticsearch.vmdk"
      unless File.exist?(file_to_disk)
        vb.customize [ "createmedium", "disk", "--filename", file_to_disk, "--format", "vmdk", "--size", 2048 * 1 ]
      end
      vb.customize [ "storageattach", "ubuntu_ELK" , "--storagectl", "SCSI", "--port", "2", "--device", "0", "--type", "hdd", "--medium", file_to_disk]
    end
    elasticsearch.vm.network "private_network", ip: "192.168.1.51", nic_type: "virtio", virtualbox__intnet: "sysadmin"
    elasticsearch.vm.network "forwarded_port", guest: 80, host: 8081
    elasticsearch.vm.network "forwarded_port", guest: 9200, host: 9200
    elasticsearch.vm.provision "shell", path: "provision_elk.sh"
  end

end 

