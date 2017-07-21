data "openstack_images_image_v2" "etcd_image" {
  name = "${var.etcd_image}"
  most_recent = true
}

data "openstack_images_image_v2" "k8s_master_image" {
  name = "${var.k8s_master_image}"
  most_recent = true
}

data "openstack_images_image_v2" "k8s_node_image" {
  name = "${var.k8s_node_image}"
  most_recent = true
}

data "openstack_images_image_v2" "k8s_admin_image" {
  name = "${var.k8s_admin_image}"
  most_recent = true
}

data "template_file" "bootstap_ansible_sh" {
  template = "${file("${path.module}/templates/bootstrap-ansible.sh.tpl")}"
  vars {
      ssh_private_key = "${var.ssh_private_key}"
  }
}

data "template_file" "ansible_external_variables_yaml" {
  template = "${file("${path.module}/templates/external_variables.yaml.tpl")}"
  vars {
      openstack_vm_domain_name = "${var.openstack_vm_domain_name}"
  }
}

resource "openstack_compute_instance_v2" "etcd_cluster" {
  count                   = "${var.etcd_count}"
  name                    = "etcd0${count.index+1}"
  flavor_name             = "${var.etcd_flavor}"
  key_pair                = "${var.etcd_keypair}"
  security_groups         = [ "${var.etcd_securitygroups}" ]

  block_device {
    uuid                  = "${data.openstack_images_image_v2.etcd_image.id}"
    source_type           = "image"
    volume_size           = "${var.etcd_volume_size}"
    boot_index            = 0
    destination_type      = "volume"
    delete_on_termination = true
  }

  network {
    name                  = "${var.etcd_network}"
  }
}

resource "openstack_compute_instance_v2" "k8s_master" {
  depends_on = [
    "openstack_compute_instance_v2.etcd_cluster",
  ]
  count                   = "1"
  name                    = "kube-master"
  flavor_name             = "${var.k8s_master_flavor}"
  key_pair                = "${var.k8s_master_keypair}"
  security_groups         = [ "${var.k8s_master_securitygroups}" ]
  # user_data               = "${data.template_file.bootstap_ansible_sh.rendered}"

  block_device {
    uuid                  = "${data.openstack_images_image_v2.k8s_master_image.id}"
    source_type           = "image"
    volume_size           = "${var.k8s_master_volume_size}"
    boot_index            = 0
    destination_type      = "volume"
    delete_on_termination = true
  }

  network {
    name                  = "${var.k8s_master_network}"
  }
}

resource "openstack_compute_instance_v2" "k8s_node" {
  depends_on = [
    "openstack_compute_instance_v2.etcd_cluster",
    "openstack_compute_instance_v2.k8s_master",
  ]
  count                   = "${var.k8s_node_count}"
  name                    = "kube0${count.index+1}"
  flavor_name             = "${var.k8s_node_flavor}"
  key_pair                = "${var.k8s_node_keypair}"
  security_groups         = [ "${var.k8s_node_securitygroups}" ]
  # user_data               = "${data.template_file.bootstap_ansible_sh.rendered}"

  block_device {
    uuid                  = "${data.openstack_images_image_v2.k8s_node_image.id}"
    source_type           = "image"
    volume_size           = "${var.k8s_node_volume_size}"
    boot_index            = 0
    destination_type      = "volume"
    delete_on_termination = true
  }

  network {
    name                  = "${var.k8s_node_network}"
  }
}

resource "openstack_compute_instance_v2" "k8s_admin" {
  depends_on = [
    "openstack_compute_instance_v2.etcd_cluster",
    "openstack_compute_instance_v2.k8s_master",
    "openstack_compute_instance_v2.k8s_node",
  ]
  count                   = "1"
  name                    = "kube-admin"
  flavor_name             = "${var.k8s_admin_flavor}"
  key_pair                = "${var.k8s_admin_keypair}"
  security_groups         = [ "${var.k8s_admin_securitygroups}" ]
  user_data               = "${data.template_file.bootstap_ansible_sh.rendered}"

  block_device {
    uuid                  = "${data.openstack_images_image_v2.k8s_admin_image.id}"
    source_type           = "image"
    volume_size           = "${var.k8s_admin_volume_size}"
    boot_index            = 0
    destination_type      = "volume"
    delete_on_termination = true
  }

  network {
    name                  = "${var.k8s_admin_network}"
  }
}

resource "null_resource" "ansible_predeploy" {
  triggers {
    key = "${uuid()}"
  }

  depends_on = [
    "openstack_compute_instance_v2.etcd_cluster",
    "openstack_compute_instance_v2.k8s_master",
    "openstack_compute_instance_v2.k8s_node",
    "openstack_compute_instance_v2.k8s_admin",
  ]

  connection {
    type        = "ssh"
    agent       = false
    timeout     = "5m"
    host        = "${openstack_compute_instance_v2.k8s_admin.0.access_ip_v4}"
    user        = "root"
    private_key = "${var.ssh_private_key}"
  }

  provisioner "remote-exec" {
    inline = [
      "echo [etcd_cluster] > /ansible/environments/dev/hosts",
      "echo \"${join("\n",formatlist("%s ansible_ssh_host=%s", openstack_compute_instance_v2.etcd_cluster.*.name, openstack_compute_instance_v2.etcd_cluster.*.access_ip_v4))}\" >> /ansible/environments/dev/hosts",
      "echo '\n[k8s_admin]' >> /ansible/environments/dev/hosts",
      "echo \"${join("\n",formatlist("%s ansible_ssh_host=%s", openstack_compute_instance_v2.k8s_admin.*.name, openstack_compute_instance_v2.k8s_admin.*.access_ip_v4))}\" >> /ansible/environments/dev/hosts",
      "echo '\n[k8s_master]' >> /ansible/environments/dev/hosts",
      "echo \"${join("\n",formatlist("%s ansible_ssh_host=%s", openstack_compute_instance_v2.k8s_master.*.name, openstack_compute_instance_v2.k8s_master.*.access_ip_v4))}\" >> /ansible/environments/dev/hosts",
      "echo '\n[k8s_node]' >> /ansible/environments/dev/hosts",
      "echo \"${join("\n",formatlist("%s ansible_ssh_host=%s", openstack_compute_instance_v2.k8s_node.*.name, openstack_compute_instance_v2.k8s_node.*.access_ip_v4))}\" >> /ansible/environments/dev/hosts",
      "echo '\n[k8s:children]\nk8s_master\nk8s_node' >> /ansible/environments/dev/hosts",
      ]
  }

  provisioner "file" {
    content     = "${data.template_file.ansible_external_variables_yaml.rendered}"
    destination = "/ansible/external_variables.yaml"
  }

  # provisioner "file" "setup_etc_hosts" {
  #   content     = "${data.template_file.etc_hosts.rendered}"
  #   destination = "/etc/hosts"
  # }

  # provisioner "remote-exec" "wait_for_provisioning" { inline = [ "sleep 10" ] }

  # provisioner "file" "setup_etc_ansible_hosts" {
  #   content     = "${data.template_file.etc_ansible_hosts.rendered}"
  #   destination = "/home/opc/hosts"
  # }

  # provisioner "remote-exec" "run_ansible" {
  #   inline = [
  #     "cd /ansible",
  #     "ansible-galaxy install -r /ansible/requirements.yaml --roles-path /ansible/roles",
  #     "ansible -m ping all",
  #   ]
  # }
}

output "etcd_cluster_info" {
  value = "${join( "," , openstack_compute_instance_v2.etcd_cluster.*.access_ip_v4)}"
}

output "etcd_cluster" {
  value = "${join( "," , openstack_compute_instance_v2.etcd_cluster.*.access_ip_v4)}"
}

output "etcd01" {
  value = "${openstack_compute_instance_v2.etcd_cluster.0.access_ip_v4}"
}

output "etcd02" {
  value = "${openstack_compute_instance_v2.etcd_cluster.1.access_ip_v4}"
}

output "etcd03" {
  value = "${openstack_compute_instance_v2.etcd_cluster.2.access_ip_v4}"
}

output "k8s_admin" {
  value = "${openstack_compute_instance_v2.k8s_admin.0.access_ip_v4}"
}