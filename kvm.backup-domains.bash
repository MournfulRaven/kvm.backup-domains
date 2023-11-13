#!/bin/bash
#

# Scripted by Valeriy Bachilo

# Usage:
#        ./kvm_backup_vms "vm-name" "3"   # will backup just <vm-name> and keep 3 backups
#        ./kvm_backup_vms                 # will backup all vm's on this host and keep 6 backups by default

BACKUP_DATE=$(date "+%Y-%m-%d.%H-%M")
DOMAIN_TO_BACKUP=$1
BACKUP_COUNT=$2

#############
# Variables #
#############
LOG_PATH="/var/log/kvm.backup-domains.log"
NETNFS_PATH="123.123.123.123:/path/to/nfs/share"
MOUNT_PATH="/path/to/local/mountpoint"
BACKUP_PATH="/path/to/local/mountpoint/backup"

# Function called in MAIN to perform backup of running domains
# Usage:   backuprunning $DOMAIN $BACKUP_COUNT
function backuprunning(){
	DOMAIN=$1
	BACKUP_COUNT_TO_KEEP=$2
	echo "'$DOMAIN':" >> $LOG_PATH
	echo -e "\tstarting backup job" >> $LOG_PATH
	# Creating backup path for domain backup
	echo -e "\tcreating backup path" >> $LOG_PATH
	BACKUP_DATE=$(date "+%Y-%m-%d.%H-%M")
	DOMAIN_BACKUP_PATH="$BACKUP_PATH/$DOMAIN"
	DOMAIN_BACKUP_PATH_DATE="$DOMAIN_BACKUP_PATH/$BACKUP_DATE"
	mkdir -p "$DOMAIN_BACKUP_PATH_DATE"
	# Checking that backup path was created
	if [ ! -d "$DOMAIN_BACKUP_PATH_DATE" ]; then
		echo -e "\tERROR! Backup path not exist. Exiting." >> $LOG_PATH
		exit 1
	fi
	
	#######################################################
	# Get the list of targets (disks) and the image paths #
	echo -e "\tgetting the list of disks to backup" >> $LOG_PATH
	TARGETS=`virsh domblklist "$DOMAIN" --details | grep file | grep -v cdrom | awk '{print $3}'`
	IMAGES=`virsh domblklist "$DOMAIN" --details | grep file | grep -v cdrom | awk '{print $4}'`
	echo -e "\tfound following disks:" >> $LOG_PATH
	for TARGET in $TARGETS; do
		echo -e "\t\t'$TARGET'" >> $LOG_PATH
	done
	
	#######################################################
	# Create the external snapshot for each target (disk) #
	echo -e "\tcreating external snapshot for targets" >> $LOG_PATH
	DISK_SPEC=""
	for TARGET in $TARGETS; do
		DISK_SPEC="$DISK_SPEC --DISK_SPEC $TARGET,snapshot=external"
	done
	virsh snapshot-create-as --domain "$DOMAIN" --name backup --no-metadata --atomic --disk-only "$DISK_SPEC" >/dev/null
	if [ $? -ne 0 ]; then
		echo -e "\tERROR! Failed to create snapshot for $DOMAIN. Exiting." >> $LOG_PATH
		exit 1
	fi
	
	###################################
	# Copy disk images to backup path #
	# Checking hash sums              #
	for IMAGE in $IMAGES; do
		NAME=`basename "$IMAGE"`
		echo -e "\tcopying disk images to backup path" >> $LOG_PATH
		cp "$IMAGE" "$DOMAIN_BACKUP_PATH_DATE"/"$NAME"
	done
	
	#######################
	# Merge snapshot back #
	echo -e "\tmerging snapshot" >> $LOG_PATH
	BACKUP_IMAGES=`virsh domblklist "$DOMAIN" --details | grep file | grep -v cdrom | awk '{print $4}'`
	for TARGET in $TARGETS; do
		virsh blockcommit "$DOMAIN" "$TARGET" --active --pivot >/dev/null
		if [ $? -ne 0 ]; then
			echo -e "\tERROR! Could not merge changes for disk $TARGET of $DOMAIN." >> $LOG_PATH
			echo -e "\tERROR! VM may be in invalid state.. Exiting." >> $LOG_PATH
			exit 1
		fi
	done
	
	######################################
	# Cleaning up left over after backup #
	echo -e "\tcleaning up" >> $LOG_PATH
	for BACKUP_IMAGE in $BACKUP_IMAGES; do
		rm -f "$BACKUP_IMAGE"
	done
	
	######################################
	# Dump the configuration information #
	echo -e "\tdumping XML configuration" >> $LOG_PATH
	virsh dumpxml "$DOMAIN" >"$DOMAIN_BACKUP_PATH_DATE/$DOMAIN.xml"
	
	#########################
	# Cleanup older backups #
	echo -e "\tcleaning up old backups" >> $LOG_PATH
	LIST=`ls -r1 "$DOMAIN_BACKUP_PATH" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]{2}-[0-9]{2}'`
	i=1
	for b in $LIST; do
		if [ $i -gt "$BACKUP_COUNT_TO_KEEP" ]; then
			echo -e "\t\tremoving old backup: "`basename $b` >> $LOG_PATH
			rm -rf "$DOMAIN_BACKUP_PATH/$b"
		fi
		i=$[$i+1]
	done
	echo -e "\tbackup job completed." >> $LOG_PATH
}

# Function called in MAIN to perform backup of shutdown domains
# Usage:   backupshutoff $DOMAIN $BACKUP_COUNT
function backupshutoff(){
	DOMAIN=$1
	BACKUP_COUNT_TO_KEEP=$2
	
	echo "'$DOMAIN':" >> $LOG_PATH
	echo -e "\tstarting backup job" >> $LOG_PATH
	
	##########################################
	# Creating backup path for domain backup #
	echo -e "\tcreating backup path" >> $LOG_PATH
	BACKUP_DATE=$(date "+%Y-%m-%d.%H-%M")
	DOMAIN_BACKUP_PATH="$BACKUP_PATH/$DOMAIN"
	DOMAIN_BACKUP_PATH_DATE="$DOMAIN_BACKUP_PATH/$BACKUP_DATE"
	mkdir -p "$DOMAIN_BACKUP_PATH_DATE"
	
	#########################################
	# Checking that backup path was created #
	if [ ! -d "$DOMAIN_BACKUP_PATH_DATE" ]; then
		echo -e "\tERROR! Backup path not exist. Exiting." >> $LOG_PATH
		exit 1
	fi
	
	#######################################################
	# Get the list of targets (disks) and the image paths #
	echo -e "\tgetting the list of disks to backup" >> $LOG_PATH
	TARGETS=`virsh domblklist "$DOMAIN" --details | grep file | grep -v cdrom | awk '{print $3}'`
	IMAGES=`virsh domblklist "$DOMAIN" --details | grep file | grep -v cdrom | awk '{print $4}'`
	echo -e "\tfound following disks:" >> $LOG_PATH
	for TARGET in $TARGETS; do
		echo -e "\t\t'$TARGET'" >> $LOG_PATH
	done
	
	###################################
	# Copy disk images to backup path #
	# Checking hash sums              #
	for IMAGE in $IMAGES; do
		NAME=`basename "$IMAGE"`
		echo -e "\tcopying disk images to backup path" >> $LOG_PATH
		cp "$IMAGE" "$DOMAIN_BACKUP_PATH_DATE"/"$NAME"
	done
	
	######################################
	# Dump the configuration information #
	echo -e "\tdumping XML configuration" >> $LOG_PATH
	virsh dumpxml "$DOMAIN" >"$DOMAIN_BACKUP_PATH_DATE/$DOMAIN.xml"
	
	#########################
	# Cleanup older backups #
	echo -e "\tcleaning up old backups" >> $LOG_PATH
	LIST=`ls -r1 "$DOMAIN_BACKUP_PATH" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]{2}-[0-9]{2}'`
	i=1
	for b in $LIST; do
		if [ $i -gt "$BACKUP_COUNT_TO_KEEP" ]; then
			echo -e "\t\tremoving old backup: "`basename $b` >> $LOG_PATH
			rm -rf "$DOMAIN_BACKUP_PATH/$b"
		fi
		i=$[$i+1]
	done
	echo -e "\tbackup job completed." >> $LOG_PATH
}

############
### MAIN ###
############

echo -e "\n\n" >> $LOG_PATH
echo "##########################################" >> $LOG_PATH
echo "# Backup job started at $BACKUP_DATE #" >> $LOG_PATH
echo "##########################################" >> $LOG_PATH

###############################################
# Defining, mounting and checking backup path #
echo "Backup path is '$BACKUP_PATH'" >> $LOG_PATH
if [ ! -d $MOUNT_PATH ]; then
	echo "ERROR! Local mount path '$MOUNT_PATH' not exists. Exiting..."; >> $LOG_PATH
	exit 1
fi
mount $NETNFS_PATH $MOUNT_PATH
if [ $? -ne 0 ]; then
	echo "ERROR! Failed to mount '$NETNFS_PATH'. Exiting..."; >> $LOG_PATH
	exit 1
fi
if [ ! -d $BACKUP_PATH ]; then
	echo "ERROR! Backup path '$BACKUP_PATH' not exists. Exiting..."; >> $LOG_PATH
	exit 1
fi
echo "NFS share '$NETNFS_PATH' mounted to '$MOUNT_PATH'" >> $LOG_PATH

#########################################################################
# If BACKUP_COUNT was not provided - choosing default "6" copies to keep #
if [ -z "$BACKUP_COUNT" ]; then
    echo "No BACKUP COUNT TO KEEP was provided. Setting default '6' copies" >> $LOG_PATH
	BACKUP_COUNT=6
fi

##############################################################################################
# If no domain was specified, script is grepping all domains on the host and backing them up #
if [ -z "$DOMAIN_TO_BACKUP" ]
then
	echo "No DOMAIN TO BACKUP was provided. Will perform backup for all domains on cluster" >> $LOG_PATH
	echo "Getting the lists of running and stoped domains" >> $LOG_PATH
	DOMAINS_RUNNING=$(virsh list --all | awk '$3=="running"' | awk '{print $2}')
	DOMAINS_SHUTOFF=$(virsh list --all | awk '$3=="shut"' | awk '{print $2}')
	echo -e "Following domains were found:" >> $LOG_PATH
	for DOMAIN_RUNNING in $DOMAINS_RUNNING; do
		echo -e "\t'$DOMAIN_RUNNING' is running" >> $LOG_PATH
	done
	for DOMAIN_SHUTOFF in $DOMAINS_SHUTOFF; do
		echo -e "\t'$DOMAIN_SHUTOFF' is turned off" >> $LOG_PATH
	done
	echo ""
	
	for DOMAIN_RUNNING in $DOMAINS_RUNNING; do
		backuprunning $DOMAIN_RUNNING $BACKUP_COUNT
	done
	for DOMAIN_SHUTOFF in $DOMAINS_SHUTOFF; do
		backupshutoff $DOMAIN_SHUTOFF $BACKUP_COUNT
	done
else
	echo "DOMAIN: '$DOMAIN_TO_BACKUP' was specified" >> $LOG_PATH
	
	################################
	# Getting domain running state #
	DOMAIN_TO_BACKUP_STATE=$(virsh dominfo --domain $DOMAIN_TO_BACKUP | grep State: | awk '{print $2}')
	if [ -z "$DOMAIN_TO_BACKUP_STATE" ]; then
		echo "DOMAIN: '$DOMAIN_TO_BACKUP' was not found or in incorrect state. Exiting." >> $LOG_PATH
		exit 1
	fi
	
	#########################################################
	# If state is 'running' or 'shut', then continue backup #
	if [ "$DOMAIN_TO_BACKUP_STATE" == "running" ]
	then
		echo "DOMAIN: '$DOMAIN_TO_BACKUP' was found in state 'running'." >> $LOG_PATH
		backuprunning $DOMAIN_TO_BACKUP $BACKUP_COUNT
	else
		if [ "$DOMAIN_TO_BACKUP_STATE" == "shut" ]
		then
			echo "DOMAIN: '$DOMAIN_TO_BACKUP' was found in state 'shut off'." >> $LOG_PATH
			backupshutoff $DOMAIN_TO_BACKUP $BACKUP_COUNT
		fi
	fi
fi

echo "Unmounting mount path" >> $LOG_PATH
umount $MOUNT_PATH
echo "Script finished job successfully" >> $LOG_PATH
echo ""
