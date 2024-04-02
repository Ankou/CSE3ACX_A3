#!/bin/bash

# Shell script to clean up resources
resources=~/resources.json

VPC=$( jq -r '."VPC-ID"' $resources )
subnet0=$( jq -r '."Subnet0"' $resources )
subnet1=$( jq -r '."Subnet1"' $resources )
PubRouteTable=$( jq -r '."PubRouteTable"' $resources )
PrivRouteTable=$( jq -r '."PrivRouteTable"' $resources )
internetGateway=$( jq -r '."internetGateway"' $resources )
#rtbassoc=$( aws ec2 describe-route-tables --filters 'Name=vpc-id,Values='$VPC | jq -r '."RouteTables"[]."Associations"[]."RouteTableAssociationId"' )
publicSG=$( jq -r '."publicSG"' $resources )
pubEC2ID=$( jq -r '."pubEC2ID"' $resources )
privateHostSG=$( jq -r '."privateHostSG"' $resources )

# Delete EC2 instance
aws ec2 terminate-instances --instance-ids $pubEC2ID | grep nothing

ec2status=$( aws ec2 describe-instances --instance-ids $pubEC2ID --query 'Reservations[].Instances[].State.Name' --output text  )

while [ $ec2status != "terminated" ]
do
  echo Status: $ec2status trying again in 10 seconds
  ec2status=$( aws ec2 describe-instances --instance-ids $pubEC2ID --query 'Reservations[].Instances[].State.Name' --output text  )
  sleep 10
done

# Delete subnet
aws ec2 delete-subnet --subnet-id $subnet0
aws ec2 delete-subnet --subnet-id $subnet1

# Delete route
aws ec2 delete-route --route-table-id $PubRouteTable --destination-cidr-block 0.0.0.0/0

# Detach internet gateway
aws ec2 detach-internet-gateway --internet-gateway-id $internetGateway --vpc-id $VPC

# Delete internet gateway
aws ec2 delete-internet-gateway --internet-gateway-id $internetGateway

# Delete Segurity Group
aws ec2 delete-security-group --group-id $privateHostSG
aws ec2 delete-security-group --group-id $publicSG

# Delete VPC
aws ec2 delete-vpc --vpc-id $VPC

# Delete key-pair
aws ec2 delete-key-pair --key-name CSE3ACX-A3-key-pair | grep nothing 

rm -f $resources
rm -f ~/.ssh/CSE3ACX-A3-key-pair.pem