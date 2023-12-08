#!/bin/bash
#

# Scripted by Valeriy Bachilo

# Usage:
#	./kvm.backup-domains.sh -n vm-name -c 3 -p /datastore/backup    # will backup just <vm-name> to </datastore/backup> and keep <3> backups
#	./kvm.backup-domains.sh -f ./config.conf                        # will take parameters from config file
#	./kvm.backup-domains.sh											# will backup all vm's on this host and keep 6 backups by default


#############
# Variables #
#############
LOG_PATH="/var/log/kvm.backup-domains.log"
BACKUP_PATH_DEFAULT="/datastore/backup"
BACKUP_COUNT_DEFAULT=6
BACKUP_RELEVANCE_PERIOD_DEFAULT=0    # Number of days


######################################################
######################################################


# Function is getting $DOMAIN for INPUT ($1)
# Output is the string of target/disk (e.g. sda) names, separated by new line
function get_targets() {
	vm_name=$1
	
	# getting all block devices
	vm_blk_list=$(virsh domblklist $vm_name --details)
	
	# filtering all block devices to get only file targets
	file_disks_targets=$(echo "$vm_blk_list" | awk '$1=="file" && $2!="cdrom" {print $3}')
	file_disks_names=$(basename "$file_disks_paths")
	
	# filtering all block devices to get only volume targets
	volume_disks_targets=$(echo "$vm_blk_list" | awk '$1=="volume" && $2!="cdrom" {print $3}')
	volume_disks_names=$(echo "$vm_blk_list" | awk '$1=="volume" && $2!="cdrom" {print $4}')
	
	# concatenate both file and volume targets
	vm_blk_targets="$file_disks_targets $volume_disks_targets"
	
	echo "$vm_blk_targets"
}


# Function is getting $DOMAIN for INPUT ($1)
# Output is the string of path to disk (e.g. /var/lib/libvirt/images/image.qcow2), separated by new line
function get_paths() {
	vm_name=$1
	
	# getting all block devices
	vm_blk_list=$(virsh domblklist $vm_name --details)
	
	# filtering all block devices to get only file paths
	file_disks_paths=$(echo "$vm_blk_list" | awk '$1=="file" && $2!="cdrom" {print $4}')
	file_disks_names=$(basename "$file_disks_paths")
	volume_disks_names=$(echo "$vm_blk_list" | awk '$1=="volume" && $2!="cdrom" {print $4}')
	
	# as far as 'domblklist' shows only names (not path) for disks in pools, 
	# following code finding and building the paths for names
	pools_volumes=$(for pool in $(virsh pool-list --all --name | awk '$1!=""'); do 
		virsh vol-list --pool "$pool" --details | awk '$3=="file" {print $1 "\t" $2}'; done)
	volume_disks_paths=$(for volume_disks_name in $volume_disks_names; do
		if (echo $pools_volumes | awk -v var="$volume_disks_name" '$1 == var')>/dev/null; then
			echo "$pools_volumes" | awk -v var="$volume_disks_name" '$1 == var {print $2}' # | awk '{print $2}'
		fi; done)
	
	# concatenate both file and volume paths
	vm_blk_paths="$file_disks_paths $volume_disks_paths"
	
	echo "$vm_blk_paths"
}


# Function called in MAIN to perform backup of running domains
# Usage:   backup_running $DOMAIN_TO_BACKUP $BACKUP_COUNT $BACKUP_PATH
function backup_running(){
	domain=$1
	backup_count_to_keep=$2
	backup_path=$3
	
	echo "'$domain':" >> $LOG_PATH
	echo -e "\tstarting backup job" >> $LOG_PATH
	
	##########################################
	# Creating backup path for domain backup #
	backup_date=$(date "+%Y-%m-%d.%H-%M")
	domain_backup_path="$backup_path/$domain"
	domain_backup_path_date="$domain_backup_path/$backup_date"
	echo -e "\tcreating backup path '$domain_backup_path_date'" >> $LOG_PATH
	mkdir -p "$domain_backup_path_date"
	
	#########################################
	# Checking that backup path was created #
	if [ ! -d "$domain_backup_path_date" ]; then
		echo -e "\tERROR! Backup path not exist. Exiting." >> $LOG_PATH
		exit 1
	fi
	
	#######################################################
	# Get the list of targets (disks) and the image paths #
	targets=($(get_targets "$domain"))   # running function to get targets and sending them to array
	targets_paths=($(get_paths "$domain"))   # running function to get paths and sending them to array
	echo -e "\tfound following disks to backup:" >> $LOG_PATH
	for ((i=0; i<${#targets[@]}; i++)); do
		echo -e "\t\t'${targets[i]}'\t\t${targets_paths[i]}" >> $LOG_PATH
	done
	
	#######################################################
	# Create the external snapshot for each target (disk) #
	echo -e "\tcreating external snapshot for targets:" >> $LOG_PATH
	# preparing arguments for 'virsh snapshot-create-as' command
	args=("--domain" "$domain" "--name" "backup" "--no-metadata" "--atomic" "--disk-only")
	for ((i=0; i<${#targets[@]}; i++)); do
		t=${targets[i]}; f=${targets_paths[i]}
		f_name=$(basename "$f"); f_dir=$(dirname "$f"); f_ext="${f_name##*.}"
		if [[ "$f_ext" != "$f_name" ]]; then
			f_name="${f_name%.*}.backup"
        else
            f_name="$f_name.backup"
        fi
		args+=("--diskspec" "$t,snapshot=external,file=$f_dir/$f_name")
	done
	echo -e "\t\tvirsh snapshot-create-as ${args[@]}" >> $LOG_PATH
	# running create snapshots command with the arguments above
	virsh snapshot-create-as "${args[@]}" >/dev/null
	if [ $? -ne 0 ]; then
		echo -e "\tERROR! Failed to create snapshot for $domain. Exiting." >> $LOG_PATH
		exit 1
	fi
	
	###################################
	# Copy disk images to backup path #
	echo -e "\tcopying disk images to backup path:" >> $LOG_PATH
	for ((i=0; i<${#targets_paths[@]}; i++)); do
		target_name=`basename "${targets_paths[i]}"`
		echo -e "\t\tcp "${targets_paths[i]}" "$domain_backup_path_date"/"$target_name"" >> $LOG_PATH
		cp "${targets_paths[i]}" "$domain_backup_path_date"/"$target_name"
	done
	
	#######################
	# Merge snapshots back #
	echo -e "\tmerging snapshots:" >> $LOG_PATH
	backup_paths=($(get_paths "$domain"))   # getting snapshot's paths to remove them after merging
	for ((i=0; i<${#targets[@]}; i++)); do
		echo -e "\t\tvirsh blockcommit "$domain" "${targets[i]}" --active --pivot" >> $LOG_PATH
		virsh blockcommit "$domain" "${targets[i]}" --active --pivot >/dev/null
		if [ $? -ne 0 ]; then
			echo -e "\tERROR! Could not merge changes for disk "${targets[i]}" of $domain." >> $LOG_PATH
			echo -e "\tERROR! VM may be in invalid state.. Exiting." >> $LOG_PATH
			exit 1
		fi
	done
	
	######################################
	# Cleaning up left over snapshot's files after backup #
	echo -e "\tcleaning up" >> $LOG_PATH
	for ((i=0; i<${#backup_paths[@]}; i++)); do
		echo -e "\t\trm -f '${backup_paths[i]}'" >> $LOG_PATH
		rm -f "${backup_paths[i]}"
	done
	
	######################################
	# Dump the configuration information #
	echo -e "\tdumping XML configuration:" >> $LOG_PATH
	echo -e "\t\tvirsh dumpxml '$domain' >'$domain_backup_path_date/$domain.xml'" >> $LOG_PATH
	virsh dumpxml "$domain" >"$domain_backup_path_date/$domain.xml"
	
	cleanup_old_backups $domain $backup_count_to_keep $backup_path
	
	echo -e "\tbackup job completed." >> $LOG_PATH
}


# Function called in MAIN to perform backup of shutdown domains
# Usage:   backup_shutoff $DOMAIN_TO_BACKUP $BACKUP_COUNT $BACKUP_PATH
function backup_shutoff(){
	domain=$1
	backup_count_to_keep=$2
	backup_path=$3
	
	echo "'$domain':" >> $LOG_PATH
	echo -e "\tstarting backup job" >> $LOG_PATH
	
	##########################################
	# Creating backup path for domain backup #
	backup_date=$(date "+%Y-%m-%d.%H-%M")
	domain_backup_path="$backup_path/$domain"
	domain_backup_path_date="$domain_backup_path/$backup_date"
	echo -e "\tcreating backup path '$domain_backup_path_date'" >> $LOG_PATH
	mkdir -p "$domain_backup_path_date"
	
	#########################################
	# Checking that backup path was created #
	if [ ! -d "$domain_backup_path_date" ]; then
		echo -e "\tERROR! Backup path not exist. Exiting." >> $LOG_PATH
		exit 1
	fi
	
	#######################################################
	# Get the list of targets (disks) and the image paths #
	targets=($(get_targets "$domain"))   # running function to get targets and sending them to array
	targets_paths=($(get_paths "$domain"))   # running function to get paths and sending them to array
	echo -e "\tfound following disks to backup:" >> $LOG_PATH
	for ((i=0; i<${#targets[@]}; i++)); do
		echo -e "\t\t'${targets[i]}'\t\t${targets_paths[i]}" >> $LOG_PATH
	done
	
	###################################
	# Copy disk images to backup path #
	echo -e "\tcopying disk images to backup path:" >> $LOG_PATH
	for ((i=0; i<${#targets_paths[@]}; i++)); do
		target_name=`basename "${targets_paths[i]}"`
		echo -e "\t\tcp "${targets_paths[i]}" "$domain_backup_path_date"/"$target_name"" >> $LOG_PATH
		cp "${targets_paths[i]}" "$domain_backup_path_date"/"$target_name"
	done
	
	######################################
	# Dump the configuration information #
	echo -e "\tdumping XML configuration:" >> $LOG_PATH
	echo -e "\t\tvirsh dumpxml '$domain' >'$domain_backup_path_date/$domain.xml'" >> $LOG_PATH
	virsh dumpxml "$domain" >"$domain_backup_path_date/$domain.xml"
	
	cleanup_old_backups $domain $backup_count_to_keep $backup_path
	
	echo -e "\tbackup job completed." >> $LOG_PATH
}

# Function to find old backups and remove them
# Usage:   cleanup_old_backups $DOMAIN_TO_BACKUP $BACKUP_COUNT $BACKUP_PATH
function cleanup_old_backups() {
	domain=$1
	backup_count_to_keep=$2
	backup_path=$3
	
	domain_backup_path="$backup_path/$domain"
	
	#########################
	# Cleanup older backups #
	echo -e "\tcleaning up old backups" >> $LOG_PATH
	old_backups=`ls -r1 "$domain_backup_path" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]{2}-[0-9]{2}'`
	i=1
	for old_backup in $old_backups; do
		if [ $i -gt "$backup_count_to_keep" ]; then
			#echo -e "\t\tremoving old backup: "`basename $old_backup` >> $LOG_PATH
			echo -e "\t\trm -rf '$domain_backup_path/$old_backup'" >> $LOG_PATH
			rm -rf "$domain_backup_path/$old_backup"
		fi
		i=$[$i+1]
	done
}

# Function to calculate difference between today and last backup date
# Usage:   since_backup $DOMAIN_TO_BACKUP $BACKUP_PATH
function since_backup() {
	domain=$1
	backup_path=$2
	
	domain_backup_path="$backup_path/$domain"
	
	# 
	# if folder not exists or no previous backups -> diff=0
	if [ -d "$domain_backup_path" ]; then
		last_backup=$(ls -1 "$domain_backup_path" | sort | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9]{2}-[0-9]{2}' | tr -d "\-\." | tail -n1)
		if [ -z last_backup ]; then
			last_backup=0
		fi
	else
		last_backup=0
	fi
	now=$(echo $BACKUP_DATE | tr -d "\-\.")
	diff=$(( $now - $last_backup + 1 ))
	echo $diff
}


############
### MAIN ###
############

BACKUP_DATE=$(date "+%Y-%m-%d.%H-%M")

echo "$(tail -1000 $LOG_PATH)" > $LOG_PATH

echo -e "\n\n" >> $LOG_PATH
echo "##########################################" >> $LOG_PATH
echo "# Backup job started at $BACKUP_DATE #" >> $LOG_PATH
echo "##########################################" >> $LOG_PATH

while getopts n:c:p:r:f: flag
do
    case "${flag}" in
        n) DOMAIN_TO_BACKUP="${OPTARG}";;
        c) BACKUP_COUNT="${OPTARG}";;
        p) BACKUP_PATH="${OPTARG}";;
		r) BACKUP_RELEVANCE_PERIOD="${OPTARG}";;
		f) CONFIG_FILE_PATH="${OPTARG}";;
    esac
done

##############################################################
# If config file provided, using parameters from config file #
if [[ -n $CONFIG_FILE_PATH ]]; 
then
	echo "Parameter '-f' provided. Will try to use config file" >> $LOG_PATH
	#
	# If other params was provided as well - error to avoid human mistakes #
	if [[ -n $DOMAIN_TO_BACKUP ]] || [[ -n $BACKUP_COUNT ]] || [[ -n $BACKUP_PATH ]] || [[ -n $BACKUP_RELEVANCE_PERIOD ]]
	then
		echo "ERROR! Parameter '-f' should be provided alone without other parameters. Exiting..." >> $LOG_PATH
		exit 1
	else
		#
		# If path to file is correct and exists #
		if [[ -f $CONFIG_FILE_PATH ]]
		then
			echo "Config file '$CONFIG_FILE_PATH' exists. Importing" >> $LOG_PATH
			source "$CONFIG_FILE_PATH"
		else
			echo "ERROR! Config file '$CONFIG_FILE_PATH' is not exists. Exiting..." >> $LOG_PATH
			exit 1
		fi
	fi
	
	#
	# Checking if arrays in config file are the same length #
	if [[ ${#DOMAIN_TO_BACKUP[@]} !=  ${#BACKUP_COUNT[@]} || ${#DOMAIN_TO_BACKUP[@]} !=  ${#BACKUP_PATH[@]} || ${#DOMAIN_TO_BACKUP[@]} != ${#BACKUP_RELEVANCE_PERIOD[@]} ]]; then
		echo "ERROR! Config file syntax is incorrect. Check an array of variables. All arrays should contain exact numbers of values. Exiting..." >> $LOG_PATH
		exit 1
	else
		echo "Config file looks ok" >> $LOG_PATH
		
		#
		# Getting length of arrays from config file. 'For' loop for each domain #
		cntr=${#DOMAIN_TO_BACKUP[@]}
		for (( c=0; c<$cntr; c++ )); do
			#
			# If DOMAIN_TO_BACKUP is empty - skipping it #
			if [ -z "${DOMAIN_TO_BACKUP[c]}" ]; then
				continue
			fi
			#
			# If BACKUP_COUNT was not provided - choosing default copies to keep #
			if [ -z "${BACKUP_COUNT[c]}" ]; then
				BACKUP_COUNT[c]="$BACKUP_COUNT_DEFAULT"
			fi
			#
			# If BACKUP_PATH was not provided - setting default $BACKUP_PATH_DEFAULT path #
			if [ -z "${BACKUP_PATH[c]}" ]; then
				BACKUP_PATH[c]="$BACKUP_PATH_DEFAULT"
			fi
			#
			# Checking if backup path exists, otherwise - exit #
			if [ ! -d "${BACKUP_PATH[c]}" ]; then
				echo "WARNING! '${BACKUP_PATH[c]}' was not found. Skipping domain '${DOMAIN_TO_BACKUP[c]}'" >> $LOG_PATH
				continue
			fi
			#
			# If BACKUP_RELEVANCE_PERIOD was not provided - choosing default BACKUP_RELEVANCE_PERIOD_DEFAULT #
			if [ -z "${BACKUP_RELEVANCE_PERIOD[c]}" ]; then
				BACKUP_RELEVANCE_PERIOD[c]="$BACKUP_RELEVANCE_PERIOD_DEFAULT"
			fi
			
			#
			# Getting domain state #
			DOMAIN_TO_BACKUP_STATE=$(virsh dominfo --domain ${DOMAIN_TO_BACKUP[c]} | grep State: | awk '{print $2}')
			if [ "$DOMAIN_TO_BACKUP_STATE" == "running" ]; then
				echo "DOMAIN: '${DOMAIN_TO_BACKUP[c]}' was found in state 'running'" >> $LOG_PATH
				#
				# Check if RELEVANCE PERIOD is less than difference between today and last backup date #
				if [ $(( ${BACKUP_RELEVANCE_PERIOD[c]} * 10000 )) -lt $(since_backup ${DOMAIN_TO_BACKUP[c]} ${BACKUP_PATH[c]}) ]; then
					backup_running ${DOMAIN_TO_BACKUP[c]} ${BACKUP_COUNT[c]} ${BACKUP_PATH[c]}
				else
					echo -e "\tskipping current backup of '${DOMAIN_TO_BACKUP[c]}' domain, cause less than '${BACKUP_RELEVANCE_PERIOD[c]}' days passed since last backup" >> $LOG_PATH
				fi

			elif [ "$DOMAIN_TO_BACKUP_STATE" == "shut" ]; then
				echo "DOMAIN: '${DOMAIN_TO_BACKUP[c]}' was found in state 'shut off'" >> $LOG_PATH
				#
				# Check if RELEVANCE PERIOD is less than difference between today and last backup date #
				if [ $(( ${BACKUP_RELEVANCE_PERIOD[c]} * 10000 )) -lt $(since_backup ${DOMAIN_TO_BACKUP[c]} ${BACKUP_PATH[c]}) ]; then
					backup_shutoff ${DOMAIN_TO_BACKUP[c]} ${BACKUP_COUNT[c]} ${BACKUP_PATH[c]}
				else
					echo -e "\tskipping current backup of '${DOMAIN_TO_BACKUP[c]}' domain, cause less than '${BACKUP_RELEVANCE_PERIOD[c]}' days passed since last backup" >> $LOG_PATH
				fi
			#
			# Skipping domains, which are now 'running' or 'shutdown' #
			else
				echo "DOMAIN: '${DOMAIN_TO_BACKUP[c]}' was not found or in incorrect state. Skipping..." >> $LOG_PATH
				continue
			fi
			
		done
		
	fi

#
# If config file not provided #
else
	echo "Parameter '-f' not provided. Continue" >> $LOG_PATH
	#
	# If $DOMAIN_TO_BACKUP specified #
	if [[ -n $DOMAIN_TO_BACKUP ]]
	then
		#
		# Will backup provided domain
		echo "DOMAIN: '$DOMAIN_TO_BACKUP' was specified" >> $LOG_PATH
		#
		# If BACKUP_COUNT was not provided - choosing default "6" copies to keep #
		if [ -z "$BACKUP_COUNT" ]; then
			echo "No BACKUP_COUNT to keep was provided. Setting default '$BACKUP_COUNT_DEFAULT' copies" >> $LOG_PATH
			BACKUP_COUNT="$BACKUP_COUNT_DEFAULT"
		fi
		#
		# If BACKUP_PATH was not provided - setting default $BACKUP_PATH_DEFAULT path #
		if [ -z "$BACKUP_PATH" ]; then
			echo "No BACKUP_PATH was provided. Setting default '$BACKUP_PATH_DEFAULT' path" >> $LOG_PATH
			BACKUP_PATH="$BACKUP_PATH_DEFAULT"
		fi
		if [ ! -d $BACKUP_PATH ]; then
			echo "ERROR! Backup path '$BACKUP_PATH' not exists. Exiting..." >> $LOG_PATH
			exit 1
		fi
		#
		# If BACKUP_RELEVANCE_PERIOD was not provided - choosing default BACKUP_RELEVANCE_PERIOD_DEFAULT #
		if [ -z "$BACKUP_RELEVANCE_PERIOD" ]; then
			echo "No BACKUP_RELEVANCE_PERIOD was provided. Setting default '$BACKUP_RELEVANCE_PERIOD_DEFAULT' period" >> $LOG_PATH
			BACKUP_RELEVANCE_PERIOD="$BACKUP_RELEVANCE_PERIOD_DEFAULT"
		fi
		
		#
		# Getting domain state #
		DOMAIN_TO_BACKUP_STATE=$(virsh dominfo --domain $DOMAIN_TO_BACKUP | grep State: | awk '{print $2}')
		if [ "$DOMAIN_TO_BACKUP_STATE" == "running" ]; then
			echo "DOMAIN: '$DOMAIN_TO_BACKUP' was found in state 'running'" >> $LOG_PATH
			if [ $(( $BACKUP_RELEVANCE_PERIOD * 10000 )) -lt $(since_backup $DOMAIN_TO_BACKUP $BACKUP_PATH) ]; then
				backup_running $DOMAIN_TO_BACKUP $BACKUP_COUNT $BACKUP_PATH
			else
				echo -e "\tskipping current backup of '$DOMAIN_TO_BACKUP' domain, cause less than '$BACKUP_RELEVANCE_PERIOD' days passed since last backup" >> $LOG_PATH
			fi

		elif [ "$DOMAIN_TO_BACKUP_STATE" == "shut" ]; then
			echo "DOMAIN: '$DOMAIN_TO_BACKUP' was found in state 'shut off'" >> $LOG_PATH
			if [ $(( $BACKUP_RELEVANCE_PERIOD * 10000 )) -lt $(since_backup $DOMAIN_TO_BACKUP $BACKUP_PATH) ]; then
				backup_shutoff $DOMAIN_TO_BACKUP $BACKUP_COUNT $BACKUP_PATH
			else
				echo -e "\tskipping current backup of '$DOMAIN_TO_BACKUP' domain, cause less than '$BACKUP_RELEVANCE_PERIOD' days passed since last backup" >> $LOG_PATH
			fi
			
		else
			echo "DOMAIN: '$DOMAIN_TO_BACKUP' was not found or in incorrect state. Exiting." >> $LOG_PATH
			exit 1
		fi
		
	else
		#
		# Will try to backup all domains on host #
		
		echo "No DOMAIN_TO_BACKUP was provided. Will perform backup for all domains on cluster" >> $LOG_PATH
		#
		# If BACKUP_COUNT was not provided - choosing default "6" copies to keep #
		if [ -z "$BACKUP_COUNT" ]; then
			echo "No BACKUP_COUNT to keep was provided. Setting default '$BACKUP_COUNT_DEFAULT' copies" >> $LOG_PATH
			BACKUP_COUNT="$BACKUP_COUNT_DEFAULT"
		fi
		#
		# If BACKUP_PATH was not provided - setting default $BACKUP_PATH_DEFAULT path #
		if [ -z "$BACKUP_PATH" ]; then
			echo "No BACKUP_PATH was provided. Setting default '$BACKUP_PATH_DEFAULT' path" >> $LOG_PATH
			BACKUP_PATH="$BACKUP_PATH_DEFAULT"
		fi
		if [ ! -d $BACKUP_PATH ]; then
			echo "ERROR! Backup path '$BACKUP_PATH' not exists. Exiting..." >> $LOG_PATH
			exit 1
		fi
		#
		# If BACKUP_RELEVANCE_PERIOD was not provided - choosing default BACKUP_RELEVANCE_PERIOD_DEFAULT #
		if [ -z "$BACKUP_RELEVANCE_PERIOD" ]; then
			echo "No BACKUP_RELEVANCE_PERIOD was provided. Setting default '$BACKUP_RELEVANCE_PERIOD_DEFAULT' period" >> $LOG_PATH
			BACKUP_RELEVANCE_PERIOD="$BACKUP_RELEVANCE_PERIOD_DEFAULT"
		fi
		
		#
		# Get all domains with their state #
		echo "Getting the list of running and stopped domains" >> $LOG_PATH
		DOMAINS=$(virsh list --all)
		DOMAINS_RUNNING=$(echo "$DOMAINS" | awk '$3=="running" {print $2}')
		DOMAINS_SHUTOFF=$(echo "$DOMAINS" | awk '$3=="shut" {print $2}')
		echo -e "Following domains were found:" >> $LOG_PATH
		for DOMAIN_RUNNING in $DOMAINS_RUNNING; do
			echo -e "\t'$DOMAIN_RUNNING' is running" >> $LOG_PATH
		done
		for DOMAIN_SHUTOFF in $DOMAINS_SHUTOFF; do
			echo -e "\t'$DOMAIN_SHUTOFF' is turned off" >> $LOG_PATH
		done
		echo ""
		
		for DOMAIN_RUNNING in $DOMAINS_RUNNING; do
			if [ $(( $BACKUP_RELEVANCE_PERIOD * 10000 )) -lt $(since_backup $DOMAIN_RUNNING $BACKUP_PATH) ]; then
				backup_running $DOMAIN_RUNNING $BACKUP_COUNT $BACKUP_PATH
			else
				echo -e "\tskipping current backup of '$DOMAIN_RUNNING' domain, cause less than '$BACKUP_RELEVANCE_PERIOD' days passed since last backup" >> $LOG_PATH
			fi
		done
		
		for DOMAIN_SHUTOFF in $DOMAINS_SHUTOFF; do
			if [ $(( $BACKUP_RELEVANCE_PERIOD * 10000 )) -lt $(since_backup $DOMAIN_SHUTOFF $BACKUP_PATH) ]; then
				backup_shutoff $DOMAIN_SHUTOFF $BACKUP_COUNT $BACKUP_PATH
			else
				echo -e "\tskipping current backup of '$DOMAIN_SHUTOFF' domain, cause less than '$BACKUP_RELEVANCE_PERIOD' days passed since last backup" >> $LOG_PATH
			fi
		done
	fi
fi

echo "Script finished job successfully" >> $LOG_PATH
echo "" >> $LOG_PATH
echo "$(tail -1000 $LOG_PATH)" > $LOG_PATH