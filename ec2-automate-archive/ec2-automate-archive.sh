#!/bin/bash
##########################################################################################
##
## Title:       AWS Glacier Archive Script
## Author:      metalcated: https://github.com/metalcated/aws-missing-tools
## Forked:	Partially forked from https://github.com/colinbjohnson/aws-missing-tools
## Date:        04/28/2016
## Version:     0.2
##
## Changelog:   0.1 - Initial Release
##		0.2 - Updated var names to be more uniform, added private IP communication
##
##########################################################################################

#define size of instance clone - if you are uising paravirtual instances make sure to use a size that works with both instance types, same goes for hvm
ec2_ami_nsize="m3.medium"
#define cert
ec2_ami_ncert="techops-2015.02.13"
#define subnet 
ec2_ami_nsubnet="subnet-d5b32bb0"
#define security group
ec2_ami_nsecgrp="sg-d53b6eb0"
#location of cert locally
ec2_ami_lcert="/opt/aws/certs/techops-2015.02.13.pem"
#define source content to rsync
ec2_instance_source="/iiidb"
#define source files target 
ec2_instance_target="/backups"

#set some colors
red=$(tput setaf 1)
green=$(tput setaf 2)
yellow=$(tput setaf 3)
normal=$(tput sgr0)

#confirms that executables required for succesful script execution are available
prerequisite_check() {
  for prerequisite in basename cut date aws fping pigz pv tar sshpass; do
    #use of "hash" chosen as it is a shell builtin and will add programs to hash table, possibly speeding execution. Use of type also considered - open to suggestions.
    hash $prerequisite &> /dev/null
    if [[ $? == 1 ]]; then #has exits with exit status of 70, executable was not found
      echo "In order to use $app_name, the executable \"$prerequisite\" must be installed." 1>&2 ; exit 70
    fi
  done
}

#get_EBS_List gets a list of available EBS instances depending upon the selection_method of EBS selection that is provided by user input
get_EBS_List() {
  case $selection_method in
    instanceid)
      if [[ -z $instanceid ]]; then
        echo "The selection method \"instanceid\" (which is $app_name's default selection_method of operation or requested by using the -s instanceid parameter) requires a instanceid (-i instanceid) for operation. Correct usage is as follows: \"-i i-6d6a0527\",\"-i instanceid -v i-6d6a0527\" or \"-i \"i-6d6a0527 i-636a0112\"\" if multiple instances are to be selected." 1>&2 ; exit 64
      fi
      ebs_selection_string="--instance-ids $instanceid"
      ;;
    tag)
      if [[ -z $tag ]]; then
        echo "The selected selection_method \"tag\" (-s tag) requires a valid tag (-t Archive,Values=true) for operation. Correct usage is as follows: \"-s tag -t Archive,Values=true.\"" 1>&2 ; exit 64
      fi
      ebs_selection_string="--filters Name=tag:$tag"
      ;;
    *) echo "If you specify a selection_method (-s selection_method) for selecting EBS instances you must select either \"instanceid\" (-s instanceid) or \"tag\" (-s tag)." 1>&2 ; exit 64 ;;
  esac
  #creates a list of all ebs instances that match the selection string from above
  ebs_archive_list=$(aws ec2 describe-instances --region $region $ebs_selection_string --output text --query 'Reservations[].Instances[].InstanceId')
  #takes the output of the previous command
  ebs_archive_list_result=$(echo $?)
  if [[ $ebs_archive_list_result -gt 0 ]]; then
    echo -e "An error occurred when running ec2-describe-instances. The error returned is below:\n$ebs_archive_list_complete" 1>&2 ; exit 70
  fi
}

create_EBS_AMI_Tags() {
  #snapshot tags holds all tags that need to be applied to a given snapshot - by aggregating tags we ensure that ec2-create-tags is called only onece
  ami_tags="Key=CreatedBy,Value=ec2-automate-archive"
  #if $name_tag_create is true then append ec2ab_${ebs_selected}_$current_date to the variable $ami_tags
  if $name_tag_create; then
    ami_tags="$ami_tags Key=Name,Value=${ec2_ami_instance_name}_${current_tag_date}"
    #ami_tags="$ami_tags Key=Name,Value=ec2ab_${ebs_selected}_$current_date"
  fi
  #if $hostname_tag_create is true then append --tag InitiatingHost=$(hostname -f) to the variable $ami_tags
  if $hostname_tag_create; then
    ami_tags="$ami_tags Key=InitiatingHost,Value='$(hostname -s)'"
  fi
  #if $purge_after_date_fe is true, then append $purge_after_date_fe to the variable $ami_tags
  if [[ -n $purge_after_date_fe ]]; then
    ami_tags="$ami_tags Key=PurgeAfterFE,Value=$purge_after_date_fe Key=PurgeAllow,Value=true"
  fi
  #if $user_tags is true, then append Volume=$ebs_selected and Created=$current_date to the variable $ami_tags
  if $user_tags; then
    ami_tags="$ami_tags Key=Volume,Value=${ebs_selected} Key=Created,Value=$current_date"
  fi
  # add sitecode tags
  if $sitecode_tag; then
    ami_tags="$ami_tags Key=Sitecode,Value=$ec2_sitecode_tag"
  fi
  #if $ami_tags is not zero length then set the tag on the snapshot using aws ec2 create-tags
  if [[ -n $ami_tags ]]; then
    echo -e "\n[${green}aws${normal}] tagging ami $ec2_ami_resource_id with the following tags: $ami_tags"
    tags_argument="--tags $ami_tags"
    aws_ec2_create_tag_result=$(aws ec2 create-tags --resources $ec2_ami_resource_id --region $region $tags_argument --output text 2>&1)
  fi
}
#check if SSH is live
checkSSH()
{
  if [[ ! -f $(which sshpass) ]]; then
    echo -e "[${red}aws${normal}] sshpass is missing, please install the sshpass binary"
    exit $?
  fi
  while ! sshpass ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${ec2_ami_lcert} -l root $ec2_instance_talk_ip 'hostname' &>/dev/null; do
    (( count++ ))
    sleep 6
    printf "\r[${green}aws${normal}] waiting for SSH to respond > ${yellow}${count}x${normal} tries"
  done
  unset count
  echo
  echo -e "[${green}aws${normal}] SSH is now active"
}
#run rsync
runRsync()
  {
  echo -e "[${green}aws${normal}] beginning rsync: ${ec2_instance_talk_ip}:${ec2_instance_source} > ${ec2_instance_target}/${ec2_ami_instance_name}"
  rsync -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${ec2_ami_lcert}" -Pav ${ec2_instance_talk_ip}:${ec2_instance_source} ${ec2_instance_target}/${ec2_ami_instance_name}> /dev/null 2>&1
  echo -e "[${green}aws${normal}] rsync complete"
}
#run archive
runArchive()
  {
  echo -e "[${green}aws${normal}] beginning archive compression: ${ec2_instance_target}/${ec2_ami_instance_name}.tgz"
  tar -c ${ec2_instance_target}/${ec2_ami_instance_name}|pv -s $(du -csb ${ec2_instance_target}/${ec2_ami_instance_name}|grep total|cut -f1)|pigz -5 > ${ec2_instance_target}/${ec2_ami_instance_name}.tgz
  echo -e "[${green}aws${normal}] archive compression complete"
}

#calls prerequisitecheck function to ensure that all executables required for script execution are available
prerequisite_check

app_name=$(basename $0)
#sets defaults
selection_method="instanceid"
#sets the "Name" tag set for a snapshot to false - using "Name" requires that ec2-create-tags be called in addition to ec2-create-snapshot
name_tag_create=false
#sets the "InitiatingHost" tag set for a snapshot to false
hostname_tag_create=false
#sets remove images to false
remove_images=false
#sets the user_tags feature to false - user_tag creates tags on snapshots - by default each snapshot is tagged with volume_id and current_date timestamp
user_tags=false
#sets sitecode tags
sitecode_tag=false
#set private_ip to false by default - recommended to enable during large file transfers to speed up the process
private_ip=false
#handles options processing

while getopts :s:p:r:v:t:cnhui opt; do
  case $opt in
    s) selection_method="$OPTARG" ;;
    r) region="$OPTARG" ;;
    v) instanceid="$OPTARG" ;;
    t) tag="$OPTARG" ;;
    n) name_tag_create=true ;;
    h) hostname_tag_create=true ;;
    c) remove_images=true ;;
    p) private_ip=true ;;
    u) user_tags=true ;;
    i) sitecode_tag=true ;;
    *) echo "Error with Options Input. Cause of failure is most likely that an unsupported parameter was passed or a parameter was passed without a corresponding option." 1>&2 ; exit 64 ;;
  esac
done

#if region is not set then:
if [[ -z $region ]]; then
  #if the environment variable $EC2_REGION is not set set to us-east-1
  if [[ -z $EC2_REGION ]]; then
    region="ap-southeast-2"
  else
    region=$EC2_REGION
  fi
fi

#sets date variable
current_date=$(date -u +%s)
current_tag_date=$(date -u +'%Y%m%d_%H:%M:%S')

#get_EBS_List gets a list of EBS instances for which a snapshot is desired. The list of EBS instances depends upon the selection_method that is provided by user input
get_EBS_List

#make random number for ec2_ami_instance_name and set new ec2_ami_instance_name
random_num=$(echo $((RANDOM%100+999)))

#the loop below is called once for each volume in $ebs_archive_list - the currently selected EBS volume is passed in as "ebs_selected"
for ebs_selected in $ebs_archive_list; do
  ec2_ami_description="ec2ami_${ebs_selected}_$current_date"
  ec2_ami_instance_name=$(aws ec2 describe-instances --region $region --output text --instance-ids $ebs_selected|grep -w "Name"|awk {'print $3'})
  ec2_ami_resource_id=$(aws ec2 create-image --no-reboot --region $region --description $ec2_ami_description --name "${ec2_ami_instance_name}-${random_num}" --instance-id $ebs_selected --output text 2>&1)
  ec2_ami_instance_id=$(aws ec2 describe-images --owners self --region $region --image-ids $ec2_ami_resource_id --output text --query 'Images[*].Name')	
  if [[ $sitecode_tag = "true" ]]; then
    ec2_sitecode_tag=$(aws ec2 describe-instances --region $region --output text --instance-ids $ebs_selected|grep -w "Sitecode"|awk {'print $3'})
  fi
  if [[ $? != 0 ]]; then
    echo -e "An error occurred when running ec2-create-snapshot. The error returned is below:\n$ec2_create_ami_result" 1>&2 ; exit 70
  fi
  create_EBS_AMI_Tags

  #after ami's are complete, run up a new instance from the ami
  while ! aws ec2 describe-images --region $region --owner self --output text|grep -w "IMAGES"|grep $ec2_ami_resource_id|grep -v pending &>/dev/null; do
        (( count++ ))
        sleep 5
	printf "\r[${green}aws${normal}] waiting for image to complete: $ec2_ami_resource_id > ${yellow}${count}x${normal} tries"
  done
  unset count
  echo
  #build new instance from ami
  #ec2_ami_runid=$(ec2-run-instances --region $region $ec2_ami_resource_id -t $ec2_ami_nsize -k $ec2_ami_ncert -s $ec2_ami_nsubnet -g $ec2_ami_nsecgrp)
  ec2_ami_runid=$(aws ec2 run-instances --region $region --image-id $ec2_ami_resource_id --instance-type $ec2_ami_nsize --key-name $ec2_ami_ncert --subnet-id $ec2_ami_nsubnet --security-groups $ec2_ami_nsecgrp)
  #get new insatnce id
  ec2_instance_id=$(echo "$ec2_ami_runid"|grep INSTANCE|awk {'print $2'})
  #set instance name (tag)
  aws ec2 create-tags --region $region --resources $ec2_instance_id --tags Key=Name,Value="${ec2_ami_instance_name}-${random_num}"
  #get attached network name
  ec2_instance_nicattach=$(echo "$ec2_ami_runid"|grep NICATTACHMENT|awk {'print $2'})
  #check if an ip is available
  if [[ -z $(aws ec2 describe-addresses --region $region --output text|grep -v eipalloc) ]]; then
	#if not allocate one
	ec2_instance_allocate=$(aws ec2 allocate-address --domain vpc --output text)
	ec2_instance_eipalloc=$(echo "$ec2_instance_allocate"|awk {'print $1'})
	ec2_instance_public_ip=$(echo "$ec2_instance_allocate"|awk {'print $3'})
  else
	ec2_instance_getaddr=$(aws ec2 describe-addresses --region $region --output text|grep -v eipalloc|head -n1)
	ec2_instance_eipalloc=$(echo "$ec2_instance_getaddr"|awk {'print $1'})
	ec2_instance_public_ip=$(echo "$ec2_instance_getaddr"|awk {'print $3'})
  fi
  #get private_ip address
  ec2_instance_private_ip=$(aws ec2 describe-instances --region $region --instance-ids $ec2_instance_id --output text --query 'Reservations[*].Instances[*].NetworkInterfaces[*].[PrivateIpAddress]')
  #which ip do we use? if you specified -p = private_ip else use public_ip
  if $private_ip; then
	ec2_instance_talk_ip=$ec2_instance_private_ip
  else
	ec2_instance_talk_ip=$ec2_instance_public_ip
  fi
  #associate thr new address with the instance
  while ! aws ec2 describe-instances --region $region --instance-id $ec2_instance_id --output text|grep -w "STATE"|grep running &>/dev/null; do
	(( count++ ))
        sleep 5
        printf "\r[${green}aws${normal}] waiting for instance to launch: $ec2_instance_id > ${yellow}${count}x${normal} tries"
  done
  unset count
  echo
  aws ec2 associate-address --region $region --instance-id $ec2_instance_id --network-interface-id $ec2_instance_nicattach --allocation-id $ec2_instance_eipalloc &>/dev/null
  #tag volumes just in case they are not removed
  ec2_instance_vols=$(aws ec2 describe-instances --region $region --instance-ids $ec2_instance_id --output text --query 'Reservations[*].Instances[*].BlockDeviceMappings[*].[Ebs.VolumeId]')
  for ivol in $ec2_instance_vols; do
	(( count++ ))
	aws ec2 create-tags --region $region --resources $ivol --tags Key=Name,Value="${ec2_ami_instance_name}-${random_num}${count}"
	ec2_ami_snapshots=$(aws ec2 describe-volumes --region $region --volume-ids $ivol --output text --query 'Volumes[*].SnapshotId')
	#tag smapshots in case they are not removed
	for amisnap in $ec2_ami_snapshots; do
        	aws ec2 create-tags --region $region --resources $amisnap --tags Key=Name,Value="${ec2_ami_instance_name}-${random_num}${count}"
	done
  done
  unset count
  #wait for interface to become live
  while ! fping -q -r 1 -a $ec2_instance_talk_ip &>/dev/null; do
	(( count++ ))
	sleep 1
	printf "\r[${green}aws${normal}] waiting for elastic IP to respond: $ec2_instance_talk_ip > ${yellow}${count}x${normal} tries"
  done
  unset count
  echo
  #check that ssh is live
  checkSSH
  #run rsync from new instance
  runRsync
  #create archive of the target directory
  count=0
  if [[ ! -d ${ec2_instance_target}/${ec2_ami_instance_name} ]]; then
	if [[ $count -eq 10 ]]; then
		echo -e "[${green}aws${normal}] backup directory does not exist after 10 tries, closing script"
		exit $?
	fi 
	(( count++ ))
	echo -e "[${green}aws${normal}] backup directory does not exist, trying rsync again"
	#run rsync from new instance again
	runRsync
  else
	#run archive of backed up files
	runArchive
  fi
  unset count
  #send archive to aws glacier
  count=0
  if [[ ! -f ${ec2_instance_target}/${ec2_ami_instance_name}.tgz ]]; then
        if [[ $count -eq 10 ]]; then
                echo -e "[${green}aws${normal}] archive creation failed does not exist after 10 tries, closing script"
                exit $?
        fi
	(( count++ ))
	echo -e "[${red}aws${normal}] archive creation failed: ${ec2_instance_target}/${ec2_ami_instance_name}.tgz, the script cannot continue\n"
	#run archive of backed up files again
	runArchive
  else
	echo -e "[${green}aws${normal}] sending archive for glacier: ${ec2_instance_target}/${ec2_ami_instance_name}.tgz"
	#upload tar file to glacier
	if [[ -n $(echo ${ec2_ami_instance_name}|grep gcccl) ]]; then
		ec2_upto_glacier=$(aws glacier upload-archive --region $region --account-id - --vault-name gcccl-backups --body ${ec2_instance_target}/${ec2_ami_instance_name}.tgz --output table)
	elif [[ -n $(echo ${ec2_ami_instance_name}|grep umelb) ]]; then
		ec2_upto_glacier=$(aws glacier upload-archive --region $region --account-id - --vault-name umelb-backups --body ${ec2_instance_target}/${ec2_ami_instance_name}.tgz --output table)
	else
		ec2_upto_glacier=$(aws glacier upload-archive --region $region --account-id - --vault-name other-backups --body ${ec2_instance_target}/${ec2_ami_instance_name}.tgz --output table)
	fi
	echo "$ec2_upto_glacier"
  fi
  unset count
  #if remove_images is true, then run purge_EBS_AMI function
  if $remove_images; then
	#once upload completes, terminate instance
	if [[ -n $(echo "$ec2_upto_glacier"|grep checksum) ]]; then
		#get volume ids of instance
		ec2_volId_del=$(aws ec2 describe-instances --region $region --instance-ids $ec2_instance_id --output text --query 'Reservations[*].Instances[*].BlockDeviceMappings[*].[Ebs.VolumeId]')
		#terminate instance
		echo -e "[${green}aws${normal}] terminating instance $(aws ec2 terminate-instances --region $region --instance-ids $ec2_instance_id > /dev/null 2>&1)"
		#deregister ami image
		echo -e "[${green}aws${normal}] deregistering ami image $(aws ec2 deregister-image --region $region --image-id $ec2_ami_resource_id)"
		#check if instance is terminated bnefore delete volumes
		while ! aws ec2 describe-instances --region $region --instance-id $ec2_instance_id --output text|grep -w "STATE"|grep terminated &>/dev/null; do
    			(( count++ ))
			sleep 5
			printf "\r[${green}aws${normal}] waiting for instance to be terminated: $ec2_instance_id > ${yellow}${count}x${normal} tries"
		done
		unset count
		echo
		#release elastic ip
                echo -e "[${green}aws${normal}] releasing elastic ip $(aws ec2 release-address --region $region --allocation-id $ec2_instance_eipalloc)"
		#finally delete volumes
		for volId in $ec2_volId_del; do
			echo -e "[${green}aws${normal}] deleting VolumeId: $volId $(aws ec2 delete-volume --region $region --volume-id $volId)"
		done
	fi
  fi
  #cleanup backup files and directory
  echo -e "[${green}aws${normal}] cleaning up temp backup files and directory"
  rm -f ${ec2_instance_target}/${ec2_ami_instance_name}.tgz
  rm -rf ${ec2_instance_target}/${ec2_ami_instance_name}
  #shoe instance complete
  echo -e "[${green}aws${normal}] Instance $ec2_instance_id / $ec2_ami_instance_name - complete"
done

#process complete
echo -e "[${green}aws${normal}] Glacier archive process complete!\n"
