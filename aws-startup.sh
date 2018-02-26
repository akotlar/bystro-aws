#!/bin/sh
cdir=$(pwd);
line=$(lsblk | grep nvme | wc -l);

sudo yum install gcc -y;
sudo yum install cpan -y;
sudo yum install openssl -y;
sudo yum install openssl-devel -y;
# Not strictly necessary, useful however for much of what we do
sudo yum install git-all -y;
# pigz for Bystro, used to speed up decompression primarily
sudo yum install pigz -y;
sudo yum install unzip -y;
sudo yum install wget -y;
# For tests involving querying ucsc directly
sudo yum install mysql-devel -y;

# for perlbrew, in case you want to install a different perl version
#https://www.digitalocean.com/community/tutorials/how-to-install-perlbrew-and-manage-multiple-versions-of-perl-5-on-centos-7
# centos 7 doesn't include bzip2
sudo yum install bzip2  -y;
sudo yum install patch -y;

rm -rf bystro;
git clone git@github.com:akotlar/bystro.git;
cd bystro;
./install-rpm.sh;

regex="([a-zA-Z0-9]+)\.clean\.yml";
for name in config/*.clean.yml; do if [[ $name =~ $regex ]]; then test="${BASH_REMATCH[1]}"; \cp "$name" config/"$test".yml && yaml w -i $_ database_dir /mnt/annotator/ && yaml w -i config/"$test".yml temp_dir /mnt/annotator/tmp; fi; done;

cd $cdir;

sudo mkdir -p /mnt/annotator;
sudo chown ec2-user -R /mnt/annotator;

if (($line >= 2)); then 
  sudo mdadm --create --verbose /dev/md0 --level=0 --name=ANNOTATOR --raid-devices=2 /dev/nvme0n1 /dev/nvme1n1;
  sudo mkfs.ext4 -L ANNOTATOR /dev/md0;
  sudo mount LABEL=ANNOTATOR /mnt/annotator;
else 
  sudo mkfs.ext4 -L ANNOTATOR /dev/nvme0n1;
  sudo mount LABEL=ANNOTATOR /mnt/annotator;
fi

#https://stackoverflow.com/questions/3557037/appending-a-line-to-a-file-only-if-it-does-not-already-exist
mountTarget='LABEL=ANNOTATOR       /mnt/annotator   ext4    defaults,nofail        0       2';
fileTarget='/etc/fstab';
grep -qF "$mountTarget" "$fileTarget" || echo "$mountTarget" | sudo tee -a "$fileTarget";

mountTarget='fs-8987f3c0.efs.us-east-1.amazonaws.com:/ /seqant nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 0 0'
grep -qF "$mountTarget" "$fileTarget" || echo "$mountTarget" | sudo tee -a "$fileTarget"

# Copy latest database files, and untar them
declare -a dbs=$(aws s3 ls s3://bystro-db/ | grep -oP "\S+.tar.gz");

sudo chown -R ec2-user /mnt/annotator;
cd /mnt/annotator;

sudo yum install mailx -y;

# run in parallel
# could also just use the fact that amazon downloads as multipart && uses many connections
# but this wouldn't help us make best use of IO (parallel decompress faculties of pigz are limited)
# aws s3 cp s3://bystro-db /mnt/annotator/ --recursive --include "/*.tar.gz";
# note that in this example $dbs would also work,
# however it would not work if doing declare -a dbs=('dm6' 'ce11' 'hg38' 'hg19')
for db in ${dbs[@]};
do
  echo "Working on $db"
  (aws s3 cp --only-show-errors s3://bystro-db/$db ./ && pigz -d -c $db | tar xvf - && rm $db) &
  pids+="$! "
done

# TODO: notify by email using SES
# TODO: email only once for success, failure, use process substitution to assign success variable
# https://stackoverflow.com/questions/356100/how-to-wait-in-bash-for-several-subprocesses-to-finish-and-return-exit-code-0
for pid in $pids; do
    wait $pid
    if [ $? -eq 0 ]; then
        echo "SUCCESS - Job $pid exited with a status of $?"
        echo "Success - got $pid" | mail -s "AWS Startup Success" -r bystrogenomics@gmail.com bystrogenomics@gmail.com
    else
        echo "FAILED - Job $pid exited with a status of $?"
        echo "Failed - Job $pid exited with a status of $?" | mail -s "AWS Startup Failed" -r bystrogenomics@gmail.com bystrogenomics@gmail.com
    fi
done

cd $cdir;


# TODO: increase ulimit
