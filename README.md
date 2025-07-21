# **Deploy a Single Node OpenShift (SNO) Cluster on KVM with Ansible**

This repository contains an Ansible playbook to automate the deployment of a Single Node OpenShift (SNO) cluster on a KVM/libvirt hypervisor running on a Fedora workstation. The playbook uses the agent-based installer method.

## **Prerequisites**

Before you begin, ensure you have the following:

* A Fedora workstation with at least 32GB of RAM and 200GB of free disk space.  
* The running user must have sudo privileges.  
* Ansible Navigator installed: sudo dnf install ansible-navigator  
* The necessary Ansible collections for libvirt, POSIX, and general community modules.

## **1\. Clone the Repository**

Clone this repository to your Fedora workstation:

~~~
git clone <repository_url>  
cd <repository_name>
~~~

## **2\. Install Ansible Collections**

Install the required Ansible collections using the requirements.yml file:

~~~
ansible-galaxy collection install -r requirements.yml
~~~

## **3\. Customize Variables**

All the customizable variables are in the vars/main.yml file. You can edit this file to change the VM specifications, network settings, and OpenShift version.

## **4. Run the Ansible Playbook**

Execute the playbook using ansible-navigator or  ansible-playbook:

~~~
ansible-navigator run sno_playbook.yml --mode stdout
OR
ansible-playbook sno_playbook.yml
~~~

The playbook will perform the following actions:

1. **Install** necessary **packages:** Install qemu-kvm, libvirt, virt-install, and other dependencies.  
2. **Configure the host:** Set up firewall rules and SELinux booleans.  
3. **Download OpenShift assets:** Download the OpenShift client (oc), installer (openshift-install), and the agent-based installer ISO.  
4. **Create the VM:** Provision a new KVM virtual machine with the specified resources.  
5. **Configure networking:** Create a static DHCP entry for the VM in the libvirt default network.  
6. **Generate installation files:** Create the install-config.yaml and agent-config.yaml files.  
7. **Start the installation:** Boot the VM from the agent-based installer ISO to begin the OpenShift installation.  
8. **Update /etc/hosts:** Add entries for the API and ingress URLs to your workstation's /etc/hosts file.

## **5\. Monitor the Installation**

The installation process will take some time. You can monitor the progress by connecting to the VM's console using virsh:

~~~
virsh console local-sno
~~~

You can also monitor the installation by running the following command:

~~~
openshift-install --dir=sno-install agent wait-for install-complete
~~~

## **6\. Access the Cluster**

Once the installation is complete, you can access the OpenShift cluster using the oc command-line tool. The kubeconfig file will be located in the sno-install/auth directory.

~~~
export KUBECONFIG=sno-install/auth/kubeconfig  
oc get nodes
~~~