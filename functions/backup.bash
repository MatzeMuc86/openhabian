#!/usr/bin/env bash
# shellcheck disable=SC2012

## Create a backup of the current openHAB configuration using openHAB's builtin tool
##
##    backup_openhab_config()
##
backup_openhab_config() {
  if ! openhab_is_installed; then
    echo "$(timestamp) [openHABian] openHAB is not installed! Canceling openHAB backup creation!"
    return 0
  fi

  local filePath
  local introText="This will create a backup of your openHAB configuration using openHAB's builtin backup tool.\\n\\nWould you like to continue?"
  local successText

  echo -n "$(timestamp) [openHABian] Beginning openHAB backup... "
  if [[ -n $INTERACTIVE ]]; then
    if (whiptail --title "openHAB backup?" --yes-button "Continue" --no-button "Cancel" --yesno "$introText" 10 80); then echo "OK"; else echo "CANCELED"; return 0; fi
  else
    echo "OK"
  fi

  echo -n "$(timestamp) [openHABian] Creating openHAB backup... "
  if filePath="$(openhab-cli backup | tail -2 | head -1 | awk -F ' ' '{print $NF}')"; then echo "OK"; else echo "FAILED"; return 1; fi
  successText="A backup of your openHAB configuration has successfully been made.\\n\\nThe backup has been stored in:\\n${filePath}"

  if [[ -n $INTERACTIVE ]]; then
    whiptail --title "Operation Successful!" --msgbox "$successText" 10 80
  else
    echo "$(timestamp) [openHABian] ${successText}"
  fi
}

## Restore a backup of the openHAB configuration using openHAB's builtin tool
##
##    backup_openhab_config(String filePath)
##
restore_openhab_config() {
  if ! openhab_is_installed; then
    echo "$(timestamp) [openHABian] openHAB is not installed! Canceling openHAB backup restoration!"
    return 0
  fi

  local backupList
  local backupPath="/var/lib/openhab2/backups"
  local filePath
  local fileSelect
  local introText="This will restore a backup of your openHAB configuration using openHAB's builtin backup tool.\\n\\nWould you like to continue?"

  readarray -t backupList < <(ls -alh "${backupPath}"/openhab2-backup-* 2> /dev/null | head -20 | awk -F ' ' '{ print $9 " " $5 }' | xargs -d '\n' -L1 basename | awk -F ' ' '{ print $1 "\n" $1 " " $2 }')

  echo -n "$(timestamp) [openHABian] Beginning restoration of openHAB backup... "
  if [[ -n $INTERACTIVE ]]; then
    if [[ -z "${backupList[*]}" ]]; then
      whiptail --title "Could not find backup!" --msgbox "We could not find any configuration backup file in the storage directory $backupPath" 8 80
      echo "CANCELED"
      return 0
    fi
    if ! (whiptail --title "Restore openHAB backup?" --yes-button "Continue" --no-button "Cancel" --yesno "$introText" 10 80); then echo "CANCELED"; return 0; fi
    if fileSelect="$(whiptail --title "Choose openHAB configuration to restore" --cancel-button "Cancel" --ok-button "Continue" --notags --menu "\\nSelect your backup from most current 20 files below:" 22 80 13 "${backupList[@]}" 3>&1 1>&2 2>&3)"; then echo "OK"; else echo "CANCELED"; return 0; fi
    filePath="${backupPath}/${fileSelect}"
  else
    filePath="$1"
  fi

  echo -n "$(timestamp) [openHABian] Restoring openHAB backup... "
  if ! cond_redirect systemctl stop openhab2.service; then echo "FAILED (stop openHAB)"; return 1; fi
  if ! (yes | cond_redirect openhab-cli restore "$filePath"); then echo "FAILED (restore)"; return 1; fi
  if cond_redirect systemctl restart openhab2.service; then echo "OK"; else echo "FAILED (restart openHAB)"; return 1; fi

  whiptail --title "Operation Successful!" --msgbox "Restoration of selected openHAB configuration was successful!" 7 80
}

## Install Amanda and configure backup user
##
##    amanda_install(String backupPass)
##
amanda_install() {
  local backupUser="backup"
  local backupPass="${1:-backup}"

  echo -n "$(timestamp) [openHABian] Configuring Amanda backup system prerequisites... "

  if ! (echo "${backupUser}:${backupPass}" | cond_redirect chpasswd); then echo "FAILED (change password)"; return 1; fi

  if grep -qs "^[[:space:]]*backup:" /etc/group; then
    if ! cond_redirect usermod --append --groups "backup" "${username:-openhabian}"; then echo "FAILED (${username:-openhabian} backup)"; return 1; fi
    if ! cond_redirect usermod --append --groups "backup" "$backupUser"; then echo "FAILED (${backupUser} backup)"; return 1; fi
  else
    if ! groupadd backup; then echo "FAILED (add group)"; return 1; fi
    if ! cond_redirect usermod --append --groups "backup" "${username:-openhabian}"; then echo "FAILED (${username:-openhabian} backup)"; return 1; fi
    if ! cond_redirect usermod --append --groups "backup" "$backupUser"; then echo "FAILED (${backupUser} backup)"; return 1; fi
  fi

  if cond_redirect chsh --shell /bin/bash "$backupUser"; then echo "OK"; else echo "FAILED (chsh ${backupUser})"; return 1; fi

  if ! dpkg -s 'amanda-common' 'amanda-server' 'amanda-client' &> /dev/null; then
    echo -n "$(timestamp) [openHABian] Installing Amanda backup system... "
    if cond_redirect apt-get install --yes amanda-common amanda-server amanda-client; then echo "OK"; else echo "FAILED"; return 1; fi
  fi
}


## Create a Amanda configuration using given inputs.
##
##    create_amanda_config(String config, String backupUser, String adminMail,
##                         String tapes, String tapeSize, String storageLoc,
##                         String awsSite, String awsBucket, String awsAccessKey,
##                         String awsSecretKey)
##
create_amanda_config() {
  local config
  local backupUser
  local adminMail
  local tapes
  local tapeSize
  local storageLoc
  local awsSite
  local awsBucket
  local awsAccessKey
  local awsSecretKey
  local amandaHosts
  local configDir
  local databaseDir
  local dumpType
  local indexDir
  local logDir
  local storageText
  local tapeChanger
  local tapeType
  local serviceTargetDir="/etc/systemd/system/"

  config="$1"
  backupUser="$2"
  adminMail="$3"
  tapes="$4"
  tapeSize="$5"
  storageLoc="$6"
  awsSite="$7"
  awsBucket="$8"
  awsAccessKey="$9"
  awsSecretKey="${10}"
  amandaHosts="/var/backups/.amandahosts"
  configDir="/etc/amanda/${config}"
  databaseDir="/var/lib/amanda/${config}/curinfo"
  dumpType="comp-user-tar"
  indexDir="/var/lib/amanda/${config}/index"
  logDir="/var/log/amanda/${config}"
  storageText="We need to prepare (\"label\") your storage media.\\n\\nFor permanent storage such as USB or NAS mounted storage, as well as for cloud based storage, we will create ${tapes} virtual containers."

  echo -n "$(timestamp) [openHABian] Creating Amanda filesystem... "
  if ! cond_redirect mkdir -p "$configDir" "$databaseDir" "$logDir" "$indexDir"; then echo "FAILED (create directories)"; return 1; fi
  if ! cond_redirect touch "$configDir"/tapelist; then echo "FAILED (touch tapelist)"; return 1; fi
  if ! (echo -e "${HOSTNAME} ${backupUser}\\n${HOSTNAME} root amindexd amidxtaped\\nlocalhost ${backupUser}\\nlocalhost root amindexd amidxtaped" > "$amandaHosts"); then echo "FAILED (Amanda hosts)"; return 1; fi
  if ! cond_redirect chown --recursive "$backupUser":backup "$amandaHosts" "$configDir" "$databaseDir" "$indexDir" "$logDir"; then echo "FAILED (chown)"; return 1; fi
  if [[ $config == "openhab-dir" ]]; then
    if ! cond_redirect chown --recursive "$backupUser":backup "$storageLoc"; then echo "FAILED (chown)"; return 1; fi
    if ! cond_redirect chmod --recursive g+rxw "$storageLoc"; then echo "FAILED (chmod)"; return 1; fi
    if ! cond_redirect mkdir -p "$storageLoc"/slots; then echo "FAILED (create slots)"; return 1; fi     # folder needed for following symlinks
    if ! cond_redirect chown --recursive "$backupUser":backup "$storageLoc"/slots; then echo "FAILED (chown slots)"; return 1; fi
    if ! cond_redirect ln -sf "$storageLoc"/slots "$storageLoc"/slots/drive0; then echo "FAILED (link drive0)"; return 1; fi
    if ! cond_redirect ln -sf "$storageLoc"/slots "$storageLoc"/slots/drive1; then echo "FAILED (link drive1)"; return 1; fi    # tape-parallel-write 2 so we need 2 virtual drives
    tapeChanger="\"chg-disk:${storageLoc}/slots\"    # The tape-changer glue script"
    tapeType="DIRECTORY"
  elif [[ $config == "openhab-AWS" ]]; then
    tapeChanger="\"chg-multi:s3:${awsBucket}/openhab-AWS/slot-{$(seq -s, 1 "$tapes")}\"    # Number of virtual containers in your tapecycle"
    tapeType="AWS"
  else
    echo "FAILED (invalid configuration: ${config})"
    return 1
  fi
  if ! (sed -e 's|%CONFIGDIR|'"${configDir}"'|g; s|%CONFIG|'"${config}"'|g; s|%ADMINMAIL|'"${adminMail}"'|g; s|%TAPESIZE|'"${tapeSize}"'|g; s|%TAPETYPE|'"${tapeType}"'|g; s|%TAPECHANGER|'"${tapeChanger}"'|g; s|%TAPES|'"${tapes}"'|g; s|%BACKUPUSER|'"${backupUser}"'|g' "${BASEDIR:-/opt/openhabian}"/includes/amanda.conf-template > "$configDir"/amanda.conf); then echo "FAILED (amanda config)"; return 1; fi
  if [[ -z $adminMail ]]; then
    if ! cond_redirect sed -i -e '/mailto/d' "$configDir"/amanda.conf; then echo "FAILED (remove mailto)"; return 1; fi
  fi
  if [[ $config = "openhab-AWS" ]]; then
    {
      echo "device_property \"S3_BUCKET_LOCATION\" \"${awsSite}\"    # Your S3 bucket location (site)"; \
      echo "device_property \"STORAGE_API\" \"AWS4\""; \
      echo "device_property \"VERBOSE\" \"YES\""; \
      echo "device_property \"S3_ACCESS_KEY\" \"${awsAccessKey}\"    # Your S3 Access Key"; \
      echo "device_property \"S3_SECRET_KEY\" \"${awsSecretKey}\"    # Your S3 Secret Key"; \
      echo "device_property \"S3_SSL\" \"YES\"    # cURL needs to have S3 Certification Authority in its CA list. If connection fails, try setting this to NO"
    } >> "$configDir"/amanda.conf
  fi
  if cond_redirect chmod 644 "$configDir"/amanda.conf; then echo "OK"; else echo "FAILED (permissions)"; return 1; fi

  echo -n "$(timestamp) [openHABian] Creating Amanda configuration... "
  if [[ $config == "openhab-dir" ]]; then
    if ! cond_redirect rm -f "$configDir"/disklist; then echo "FAILED (clean disklist)"; return 1; fi
    # Don't backup full SD by default as this can cause issues with large cards
    if [[ -n $INTERACTIVE ]]; then
      if (whiptail --title "Backup raw SD card?" --defaultno --yes-button "Yes" --no-button "No" --yesno "Do you want to create raw disk backups of your SD card?\\n\\nThis is only recommended if your SD card is 16GB or less, otherwise this can take too long.\\n\\nYou can change this at any time by editing:\\n'${configDir}/disklist'" 13 80); then
        echo "${HOSTNAME}  /dev/mmcblk0                  comp-amraw" >> "$configDir"/disklist
      fi
    fi
  fi
  {
    echo "${HOSTNAME}  /boot                         ${dumpType}"; \
    echo "${HOSTNAME}  /etc                          ${dumpType}"
  } >> "$configDir"/disklist
  if [[ -d /var/lib/openhab2 ]]; then
    echo "${HOSTNAME}  /var/lib/openhab2             ${dumpType}" >> "$configDir"/disklist
  fi
  if [[ -d /opt/zram/persistence.bind ]]; then
    echo "${HOSTNAME}  /opt/zram/persistence.bind    ${dumpType}" >> "$configDir"/disklist
  fi
  if [[ -d /var/lib/homegear ]]; then
    echo "${HOSTNAME}  /var/lib/homegear             ${dumpType}" >> "$configDir"/disklist
  fi
  if [[ -d /opt/find3/server/main ]]; then
    echo "${HOSTNAME}  /opt/find3/server/main        ${dumpType}" >> "$configDir"/disklist
  fi
  {
    echo "index_server \"localhost\""; \
    echo "tapedev \"changer\""; \
    echo "auth \"local\""
  } > "$configDir"/amanda-client.conf
  if cond_redirect chmod 644 "$configDir"/disklist "$configDir"/amanda-client.conf; then echo "OK"; else echo "FAILED (permissions)"; return 1; fi

  echo -n "$(timestamp) [openHABian] Preparing storage location... "
  if [[ -n $INTERACTIVE ]]; then
    if ! (whiptail --title "Storage container creation?" --yes-button "Continue" --no-button "Cancel" --yesno "$storageText" 10 80); then echo "CANCELED"; return 0; fi
  fi
  until [[ $tapes -le 0 ]]; do
    if [[ $config == "openhab-dir" ]]; then
      if ! cond_redirect mkdir -p "${storageLoc}/slots/slot${tapes}"; then echo "FAILED (slot${tapes})"; return 1; fi
      if ! cond_redirect chown --recursive "$backupUser":backup "${storageLoc}/slots/slot${tapes}"; then echo "FAILED (chown slot${tapes})"; return 1; fi
    elif [[ $config == "openhab-AWS" ]]; then
      if ! cond_redirect su - "$backupUser" -c "amlabel ${config} ${config}-${tapes} slot ${tapes}"; then echo "FAILED (amlabel)"; return 1; fi
    else
      echo "FAILED (invalid configuration: ${config})"
      return 1
    fi
    ((tapes-=1))
  done
  echo "OK"

  if ! sed -e "s|%CONFIG|${config}|g" "${BASEDIR:-/opt/openhabian}"/includes/amdump.service-template >"${serviceTargetDir}/amdump-${config}.service"; then echo "FAILED (create Amanda ${config} backup service)"; return 1; fi
  if ! cp "${BASEDIR:-/opt/openhabian}"/includes/amdump.timer "${serviceTargetDir}/amdump-${config}.timer"; then echo "FAILED (create Amanda ${config} timer)"; return 1; fi
  if ! cond_redirect systemctl -q daemon-reload &> /dev/null; then echo "FAILED (daemon-reload)"; return 1; fi
  if ! cond_redirect systemctl enable "amdump-${config}.service"; then echo "FAILED (amdump-${config} service enable)"; return 1; fi
  if ! cond_redirect systemctl enable "amdump-${config}.timer"; then echo "FAILED (amdump-${config} timer enable)"; return 1; fi
  if [[ $tapeType == "DIRECTORY" ]]; then
    # shellcheck disable=SC2154
    if ! sed -e "s|%STORAGE|${storage}|g" "${BASEDIR:-/opt/openhabian}"/includes/amandaBackupDB.service-template >"${serviceTargetDir}"/amandaBackupDB.service; then echo "FAILED (create Amanda DB backup service)"; return 1; fi
    if ! cp "${BASEDIR:-/opt/openhabian}"/includes/amandaBackupDB.timer "${serviceTargetDir}"/; then echo "FAILED (create Amanda DB timer)"; return 1; fi
    if ! cond_redirect systemctl -q daemon-reload &> /dev/null; then echo "FAILED (daemon-reload)"; return 1; fi
    if ! cond_redirect mkdir -p "$storageLoc"/amanda-backups; then echo "FAILED (create amanda-backups)"; return 1; fi
    if ! cond_redirect chown --recursive "$backupUser":backup "$storageLoc"/amanda-backups; then echo "FAILED (chown amanda-backups)"; return 1; fi
    if ! cond_redirect systemctl enable "amandaBackupDB.service"; then echo "FAILED (Amanda DB backup service enable)"; return 1; fi
    if ! cond_redirect systemctl enable "amandaBackupDB.timer"; then echo "FAILED (Amanda DB backup timer enable)"; return 1; fi
  fi
}


## Setup a Amanda based backup using local storage, AWS, or a set of SD cards.
##
##    amanda_setup()
##
amanda_setup() {
  if [[ -z $INTERACTIVE ]]; then
    echo "$(timestamp) [openHABian] Amanda backup setup must be run in interactive mode! Canceling Amanda backup setup!"
    return 0
  fi

  local config
  local backupUser
  local adminMail
  local tapes
  local tapeSize
  local storageLoc
  local awsSite
  local awsBucket
  local awsAccessKey
  local awsSecretKey
  local adminMail
  local backupPass
  local backupPass1
  local backupPass2
  local eximText
  local introText
  local queryText
  local successText

  backupUser="backup"
  eximText="It appears EXIM4 is not installed as a mail transfer agent.\\n\\nAmanda needs a MTA to be able to send emails. Only choose to ignore this if you know that there is a working MTA other than EXIM4 on your system.\\n\\nDo you want to continue with EXIM4 installation?"
  queryText="You are about to install the Amanda backup solution.\\nDocumentation is available at '/opt/openhabian/docs/openhabian-amanda.md' or https://github.com/openhab/openhabian/blob/master/docs/openhabian-amanda.md\\nHave you read this document? If not, please do so now, as you will need to follow the instructions provided there in order to successfully complete installation of Amanda.\\n\\nProceeding will setup a backup mechanism to allow for saving your openHAB setup and modifications to either USB attached or Amazon cloud storage.\\nYou can add your own files/directories to be backed up, and you can store and create clones of your openHABian SD card to have an pre-prepared replacement in case of card failures.\\n\\nWARNING: running this setup will overwrite any previous Amanda backup configurations.\\n\\nWould you like to begin setup?"
  successText="Setup was successful.\\n\\nAmanda backup tool is now taking backups around 01:00. For further readings, start at http://wiki.zmanda.com/index.php/User_documentation."

  echo -n "$(timestamp) [openHABian] Beginning setup of the Amanda backup system... "
  if (whiptail --title "Amanda backup installation" --yes-button "Continue" --no-button "Cancel" --defaultno --yesno "$queryText" 24 80); then echo "OK"; else echo "CANCELED"; return 0; fi

  if ! dpkg -s 'exim4' &> /dev/null; then
    if (whiptail --title "MTA missing?" --yes-button "Install EXIM4" --no-button "Ignore" --yesno "$eximText" 12 80); then
      if ! exim_setup; then return 1; fi
    fi
  fi

  echo -n "$(timestamp) [openHABian] Configuring Amanda backup system prerequisites... "
  adminMail="$(whiptail --title "Amanda backup reports?" --inputbox "\\nEnter the eMail address to send backup reports to:" 9 80 3>&1 1>&2 2>&3)"
  if [[ -z $adminMail ]]; then
    adminMail="root@${HOSTNAME}"
  fi
  while [[ -z $backupPass ]]; do
    if ! backupPass1="$(whiptail --title "Authentication Setup" --passwordbox "\\nEnter a password for ${backupUser}:" 9 80 3>&1 1>&2 2>&3)"; then echo "CANCELED"; return 0; fi
    if ! backupPass2="$(whiptail --title "Authentication Setup" --passwordbox "\\nPlease confirm the password:" 9 80 3>&1 1>&2 2>&3)"; then echo "CANCELED"; return 0; fi
    if [[ $backupPass1 == "$backupPass2" ]] && [[ ${#backupPass1} -ge 8 ]] && [[ ${#backupPass2} -ge 8 ]]; then
      backupPass="$backupPass1"
    else
      whiptail --title "Authentication Setup" --msgbox "Password mismatched, blank, or less than 8 characters... Please try again!" 7 80
    fi
  done

  if ! amanda_install "$backupPass"; then return 1; fi

  if (whiptail --title "Backup using locally attached storage?" --yes-button "Yes" --no-button "No" --yesno "Would you like to setup a backup mechanism based on locally attached or NAS mounted storage?" 8 80); then
    config="openhab-dir"
    if ! storageLoc="$(whiptail --title "Storage directory?" --inputbox "\\nWhat is the directory backups should be stored in?\\n\\nYou can specify any locally accessible directory, no matter if it's located on the internal SD card, an external USB-attached device such as a USB stick, HDD, or a NFS/CIFS share." 13 80 3>&1 1>&2 2>&3)"; then echo "CANCELED"; return 0; fi
    tapes="15"
    if ! tapeSize="$(whiptail --title "Storage capacity?" --inputbox "\\nHow much storage do you want to dedicate to your backup in megabytes?\\n\\nRecommendation: 2-3 times the amount of data to be backed up." 11 80 3>&1 1>&2 2>&3)"; then echo "CANCELED"; return 0; fi
    ((tapeSize/=tapes))
    if ! create_amanda_config "$config" "$backupUser" "$adminMail" "$tapes" "$tapeSize" "$storageLoc"; then return 1; fi
    whiptail --title "Amanda config setup successful" --msgbox "$successText" 10 80
  fi
  if (whiptail --title "Backup using Amazon AWS?" --yes-button "Yes" --no-button "No"  --defaultno --yesno "Would you like to setup a backup mechanism based on Amazon Web Services?\\n\\nYou can get 5 GB of S3 cloud storage for free on https://aws.amazon.com/. For hints see http://markelov.org/wiki/index.php?title=Backup_with_Amanda:_tape,_NAS,_Amazon_S3#Amazon_S3\\nPlease setup your S3 bucket on Amazon Web Services NOW if you have not done so. Remember the name has to be unique in AWS namespace." 14 90); then
    config="openhab-AWS"
    if ! awsSite="$(whiptail --title "AWS bucket site location?" --inputbox "\\nEnter the AWS site location you want to use (e.g. \"eu-central-1\"):" 9 80 3>&1 1>&2 2>&3)"; then echo "CANCELED"; return 0; fi
    if ! awsBucket="$(whiptail --title "AWS bucket name?" --inputbox "\\nEnter the bucket name you created on AWS (only the part after the last ':' of the ARN):" 10 80 3>&1 1>&2 2>&3)"; then echo "CANCELED"; return 0; fi
    if ! awsAccessKey="$(whiptail --title "AWS access key?" --inputbox "\\nEnter the AWS access key you obtained at S3 setup time:" 9 80 3>&1 1>&2 2>&3)"; then echo "CANCELED"; return 0; fi
    if ! awsSecretKey="$(whiptail --title "AWS secret key?" --inputbox "\\nEnter the AWS secret key you obtained at S3 setup time:" 9 80 3>&1 1>&2 2>&3)"; then echo "CANCELED"; return 0; fi
    tapes="15"
    if ! tapeSize="$(whiptail --title "Storage capacity?" --inputbox "\\nHow much storage do you want to dedicate to your backup in megabytes?\\n\\nRecommendation: 2-3 times the amount of data to be backed up." 11 80 3>&1 1>&2 2>&3)"; then echo "CANCELED"; return 0; fi
    ((tapeSize/=tapes))
    if ! create_amanda_config "$config" "$backupUser" "$adminMail" "$tapes" "$tapeSize" "AWS" "$awsSite" "$awsBucket" "$awsAccessKey" "$awsSecretKey"; then return 1; fi
    whiptail --title "Amanda config setup successful" --msgbox "$successText" 10 80
  fi
}


## "raw" copy partition using dd or mount and use rsync to sync "diff"
## Valid "method" arguments: "raw", "diff"
## Periodically activated by systemd timer units (raw copy on 1st of month, rsync else)
##
##    mirror_SD(String method, String destinationDevice)
##
mirror_SD() {
  local src="/dev/mmcblk0"
  local dest
  local start
  local syncMount="/storage/syncmount"
  local failed="no"
  
  # shellcheck disable=SC2154
  if [[ -n "$INTERACTIVE" ]]; then
    select_blkdev "^sd" "Setup SD mirroring" "Select the USB attached disk device to copy the internal SD card data to"
    if [[ -z "$retval" ]]; then return 0; fi
    dest="/dev/$retval"
  else
    dest="${2:-${backupdrive}}"
  fi
  if [[ "${src}" == "${dest}" ]]; then
    echo "FAILED (source = destination)"
    return 1
  fi
  if ! [[ $(blockdev --getsize64 "${dest}") ]]; then
    echo "FAILED (bad destination)"
    return 1
  fi
  # shellcheck disable=SC2143
  if [[ $(mount | grep "${dest}" &>/dev/null) ]]; then
    echo "FAILED (destination mounted)"
    return 1
  fi
  if [[ "$1" == "raw" ]]; then
    echo "Creating a raw partition copy, be prepared this may take long such as 20-30 minutes for a 16 GB SD card"
    if ! cond_redirect dd if="${src}" bs=1M of="${dest}"; then echo "FAILED (raw device copy)"; return 1; fi
    if ! cond_redirect fsck -y -t vfat "${dest}1"; then echo "FAILED (dirty fsck ${dest}1)   "; failed="yes"; fi
    if ! cond_redirect fsck -y -t ext4 "${dest}2"; then echo "FAILED (dirty fsck ${dest}2)"; failed="yes"; fi
    if [[ "$failed" == "no" ]]; then
      echo "OK"
      return 0
    else
      return 1
    fi
  fi

  if [[ "$1" == "diff" ]]; then
    if [[ ! -d $syncMount ]]; then
      mkdir -p "$syncMount"
    fi
    if [[ -n "$INTERACTIVE" ]]; then
      select_blkdev "^-sd" "select partition" "Select the partition to copy the internal SD card data to"
      dest="/dev/$retval"
    else
      dest="${dest}3"
    fi

    mount "$dest" "$syncMount"
    rsync --one-file-system -avRh "/" "$syncMount"
    if ! (umount "$syncMount" &> /dev/null); then
      sleep 1
      umount -l "$syncMount" &> /dev/null
    fi
  fi
}


## setup mirror/sync of boot and / partitions
##
##   setup_mirror_SD()
##
setup_mirror_SD() {
  local dest
  local srcSize
  local destSize
  local minSize
  local serviceTargetDir="/etc/systemd/system/"
  local storageDir="${storagedir:-/storage}"
  local sizeError="your destination SD card device does not have enough space, it needs to have at least twice as much as the source"
  local infoText1="DANGEROUS OPERATION, USE WITH PRECAUTION!\\n\\nThis will *copy* your system root from your SD card to a USB attached card writer device. Are you sure"
  local infoText2="is an SD card writer device equipped with a dispensible SD card ? Are you this will destroy all data on that card and you want to proceed writing to this device ?"


  echo -n "$(timestamp) [openHABian] Setting up automated SD mirroring and backup... "
  if [[ "$1" == "remove" ]]; then
    cond_redirect systemctl disable sdrsync.service sdrawcopy.service sdrsync.timer sdrawcopy.timer
    rm -f ${serviceTargetDir}/sdr*.{service,timer}
    cond_redirect systemctl -q daemon-reload &> /dev/null
    return 0
  fi
  if [[ "$1" != "install" ]]; then echo "FAILED"; return 1; fi

  if ! is_pi; then
    if [[ -n "$INTERACTIVE" ]]; then
      whiptail --title "Incompatible hardware detected" --msgbox "Mirror SD: this option is for the Raspberry Pi only." 10 60
    fi
    echo "FAILED"; return 1
  fi

  # shellcheck disable=SC2154
  if [[ -n "$UNATTENDED" ]] && [[ -z "$backupdrive" ]]; then return 0; fi

  if [[ -n "$INTERACTIVE" ]]; then
    select_blkdev "^sd" "Setup SD mirroring" "Select USB device to copy the internal SD card data to"
    if [[ -z "$retval" ]]; then return 0; fi
    dest="/dev/${retval}"
  else
    # shellcheck disable=SC2154
    dest="${backupdrive}"
  fi
  if [[ ! $(blockdev --getsize64 "${dest}") ]]; then
    echo "FAILED (bad destination)"
    return 1
  fi
  # shellcheck disable=SC2143
  if [[ $(mount | grep "${dest}" &>/dev/null) ]]; then
    echo "FAILED (destination mounted)"
    return 1
  fi

  infoText="$infoText1 $dest $infoText2"
  srcSize="$(blockdev --getsize64 /dev/mmcblk0)"
  minSize="$((19 * srcSize / 10))"	# to accomodate for slight differences in SD sizes
  destSize="$(blockdev --getsize64 "$dest")"
  if [[ "$destSize" -lt "$minSize" ]]; then
    if [[ -n "$INTERACTIVE" ]]; then
      whiptail --title "insufficient space" --msgbox "$sizeError" 9 80
    fi
    echo "FAILED (insufficient space)"; return 1;
  fi

  # copy partition table
  start="$(fdisk -l /dev/mmcblk0 | head -1 | cut -d' ' -f7)"
  ((destSize-=start))
  (sfdisk -d /dev/mmcblk0; echo "/dev/mmcblk0p3 : start=${start},size=${destSize}, type=83") | sfdisk "$dest"
  partprobe
  cond_redirect mke2fs -F -t ext4 "${dest}3"
  mkdir -p "${storageDir}"
  # shellcheck disable=SC2154
  if ! sed -e "s|%DEVICE|${dest}3|g" -e "s|%BKPDIR|${storageDir}|g" "${BASEDIR:-/opt/openhabian}"/includes/storage.mount > "${serviceTargetDir}"/storage.mount; then echo "FAILED (create storage mount)"; fi
  if ! cond_redirect systemctl enable --now storage.mount; then echo "FAILED (enable storage mount)"; return 1; fi

  if [[ -n $INTERACTIVE ]]; then
    if ! (whiptail --title "Copy system root to $dest" --yes-button "Continue" --no-button "Back" --yesno "$infoText" 22 116); then echo "CANCELED"; return 0; fi
  fi

  if ! sed -e "s|%DEST|${dest}|g" "${BASEDIR:-/opt/openhabian}"/includes/sdrawcopy.service_template > "${serviceTargetDir}"/sdrawcopy.service; then echo "FAILED (create raw SD copy service)"; fi
  if ! sed -e "s|%DEST|${dest}|g" "${BASEDIR:-/opt/openhabian}"/includes/sdrsync.service_template > "${serviceTargetDir}"/sdrsync.service; then echo "FAILED (create rsync service)"; fi
  if cond_redirect cp "${BASEDIR:-/opt/openhabian}"/includes/sd*.timer "${serviceTargetDir}"/; then echo "OK"; else rm -f "${serviceTargetDir}/sdr*.service"; echo "FAILED (setup copy timers)"; return 1; fi
  if ! cond_redirect install -m 755 "${BASEDIR:-/opt/openhabian}"/includes/mirror_SD /usr/local/sbin; then echo "FAILED (install mirror_SD)"; return 1; fi
  cond_redirect systemctl -q daemon-reload &> /dev/null
  if ! cond_redirect systemctl enable --now sdrawcopy.timer sdrsync.timer; then echo "FAILED (enable timed SD sync start)"; return 1; fi

  echo "OK"

  if [[ -z $INTERACTIVE ]]; then
    amanda_install
    create_amanda_config "${storageconfig:-openhab-dir}" "backup" "${adminmail:-root@${HOSTNAME}}" "${storagetapes:-15}" "${storagecapacity:-1024}" "${storagedir:-/storage}"
  fi
}
