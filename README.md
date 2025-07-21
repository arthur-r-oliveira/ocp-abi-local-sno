# **Deploy a Single Node OpenShift (SNO) Cluster on KVM with Ansible**

This repository contains an Ansible playbook to automate the deployment of a Single Node OpenShift (SNO) cluster on a KVM/libvirt hypervisor running on a Fedora workstation. The playbook uses the [agent-based installer method](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/installing_an_on-premise_cluster_with_the_agent-based_installer/preparing-to-install-with-agent-based-installer).

## **Prerequisites**

Before you begin, ensure you have the following:

* A Fedora workstation with at least 32GB of RAM and 200GB of free disk space.  
* A user with sudo privileges.  
* Ansible Navigator installed: sudo dnf install ansible-navigator  
* Podman or Docker installed and running.

## **1. Clone or Set Up the Project Files**

Ensure all the project files (`sno\_playbook.yml`, `vars/main.yml`, etc.) are in a single directory on your Fedora workstation.

## **2. Create the Ansible Navigator Configuration**

ansible-navigator uses execution environments to run playbooks in a consistent and isolated manner.

First, create a file named `requirements.yml` to specify the collections needed:

~~~
# requirements.yml  
collections:  
  - community.libvirt  
  - ansible.posix  
  - community.general
~~~

Next, create a file named `execution-environment.yml`. This file defines how to build your custom environment:

~~~
# execution-environment.yml  
version: 3  
images:  
  base_image:  
    name: quay.io/ansible/creator-ee:latest  
dependencies:  
  galaxy: requirements.yml
~~~

Finally, create the main `ansible-navigator.yml` configuration file. This tells ansible-navigator to use the build instructions you just defined:

~~~
# ansible-navigator.yml
---  
ansible-navigator:  
  execution-environment:  
    build:  
      file: execution-environment.yml  
      context: .  
    image: sno-ee:latest  
    pull:  
      policy: missing  
    container-engine: podman  
    volume-mounts:  
      - src: "./"  
        dest: "/home/runner/project"
~~~

## **3. Customize Variables**

All the customizable variables are in the vars/main.yml file.

**IMPORTANT:**

* You must update the paths for `pull_secret_path` and `ssh_public_key_path`.  
* The `sno_domain` should be a non-reserved domain (e.g., sno.test, mycluster.example). Do not use .localhost as it will conflict with systemd-resolved and cause the installation to fail.

## **4. Run the Ansible Playbook**

Before running the playbook, especially after a failed attempt, ensure you have a clean environment:

~~~
# Destroy any existing VM  
sudo virsh destroy local-sno  
sudo virsh undefine local-sno --remove-all-storage
# Delete the old installation directory  
sudo rm -rf /home/arolivei/sno-install
~~~

Execute the playbook using `ansible-navigator`. The --mode stdout flag provides output similar to `ansible-playbook`.

~~~
ansible-navigator run sno_playbook.yml --mode stdout
~~~

## **5. Monitor the Installation**

The installation process will take some time. You can monitor the progress by connecting to the VM's VNC console using a tool like virt-viewer or the Cockpit web interface.

To monitor the installation progress from the host, run the following command. You must use sudo because the installation directory is owned by root.

~~~
sudo openshift-install --dir={{ sno_install_dir }} agent wait-for install-complete
~~~

## **6. Access the Cluster**

Once the installation is complete, the wait-for command will exit and provide you with the command to access your cluster. The kubeconfig file will be located in the sno-install/auth directory.

~~~
export KUBECONFIG={{ sno_install_dir }}/auth/kubeconfig  
oc get nodes
~~~

## **Troubleshooting**

* **panic: interface conversion: asset.Asset is nil:** This error occurs when the wait-for command is run against an incomplete or stale installation directory. Always perform the full cleanup steps before re-running the playbook.  
* **DNS Wildcard Error:** If the installation fails with a DNS wildcard error, ensure you are not using .localhost for your sno\_domain in vars/main.yml.  
* **Blank Console:** If the virsh console is blank, connect to the VM's graphical console using virt-viewer or Cockpit to see the boot process.  
* **Libvirt Errors:** If you encounter errors from libvirt about machine types, audio backends, or XML validation, ensure you are using the latest version of the vm-definition.xml.j2 template from this project.