This tutorial describes how to setup an OMERO instance on SURF Research Cloud.

<https://github.com/maartenpaul/LCO-researchcloud-items/tree/main/playbooks/roles/omero>

Image data and the OMERO database are ideally stored on permanent storage. In SRC you are able to attach storage to a VM, which is automatically mounted on start. In this way you can also redeploy OMERO on a different VM with different hardware specs.

## 1. Create permanent storage

Go to the storage tab, click `+` follow the steps, make sure to select the correct organization and the choose the amount of storage you like to have.

Choose a name for the storage, note this name as we will need it for automatically installation of OMERO.

![[image1.png]]

## 2. Create new workspace

Now go to the Workspace tab, click `+` or click create new workspace

You need to select a catalog item

- search for OMERO
- (current only available when part of the collaboration)
- choose a configuration: e.g. 8 core 32gb
- Make sure to select Ubuntu 22.04 (there is an issue with the docker component on 24.04)

![[image2.png]]

- In the next step make sure to select the storage you create before
- optional: if you like to connect multiple VMs together you can connect to a private network (you need to create first)
- Next step need to define workspace parameters
  - choose a hostname
  - OMERO_DATA_PATH: enter here the following path with the name of the attached storage
    - `/data/[storagename]
- Direct access: provide direct access to OMERO.web via nginx reverse proxy
- Port for direct access:
- SRAM login, before logging into OMERO need to enter SRAM credentials so need to be part of the organization to access OMERO, still need a separate account for OMERO
- OMERO root password: provide a initial password otherwise a random generated password is used. Than can be accessed via SSH
- Press submit: the virtual machine is build and after a while will be accessible
- To access OMERO.web need to open port 80 (TCP), which redirects to nginx![[image3.png]]

For access to the OMERO API also need to open (4063-4064, tcp)

### Notes

- It is possible to turn on/off the SRAM access by editing the nginx configuration: https://github.com/maartenpaul/LCO-researchcloud-items/tree/main/playbooks/roles/omero#access-modes-and-switching-them-on-a-live-workspace
- For API access need to open
- Currently docker component fails on ubuntu 24.04
