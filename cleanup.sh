#!/bin/bash

# Flask Portfolio App - AWS Resource Cleanup Script
# Deletes all resources created by deploy.sh

set -e

DEPLOYMENT_FILE="infra/deployment-info.txt"

echo "🧹 Starting Flask Portfolio App cleanup..."

# Check if deployment info file exists
if [ ! -f "$DEPLOYMENT_FILE" ]; then
    echo "❌ Deployment info file not found: $DEPLOYMENT_FILE"
    echo "Cannot proceed with cleanup without deployment information."
    exit 1
fi

# Source the deployment information
source $DEPLOYMENT_FILE

echo "📋 Found deployment from $(head -1 $DEPLOYMENT_FILE)"
echo "🎯 Target resources:"
echo "   S3 Bucket: $S3_BUCKET"
echo "   RDS Instance: $RDS_IDENTIFIER"
echo "   EC2 Instance: $INSTANCE_ID"
echo "   Security Group: $SECURITY_GROUP_ID"
echo "   IAM Role: $IAM_ROLE"
echo ""

read -p "⚠️  Are you sure you want to delete ALL these resources? (yes/no): " confirmation
if [ "$confirmation" != "yes" ]; then
    echo "❌ Cleanup cancelled."
    exit 0
fi

echo "🚀 Starting resource cleanup..."

# Step 1: Terminate EC2 Instance
if [ ! -z "$INSTANCE_ID" ]; then
    echo "🖥️ Step 1: Terminating EC2 instance..."
    aws ec2 terminate-instances --instance-ids $INSTANCE_ID > /dev/null
    echo "✅ EC2 instance termination initiated: $INSTANCE_ID"
    
    echo "⏳ Waiting for instance to terminate..."
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID
    echo "✅ EC2 instance terminated successfully"
else
    echo "⚠️ No EC2 instance ID found"
fi

# Step 2: Delete RDS Instance
if [ ! -z "$RDS_IDENTIFIER" ]; then
    echo "🗃️ Step 2: Deleting RDS database..."
    aws rds delete-db-instance \
        --db-instance-identifier $RDS_IDENTIFIER \
        --skip-final-snapshot \
        --delete-automated-backups > /dev/null
    echo "✅ RDS deletion initiated: $RDS_IDENTIFIER"
    
    echo "⏳ Waiting for RDS to be deleted (this may take several minutes)..."
    aws rds wait db-instance-deleted --db-instance-identifier $RDS_IDENTIFIER
    echo "✅ RDS database deleted successfully"
    
    # Delete DB subnet group
    DB_SUBNET_GROUP="portfolio-app-subnet-group"
    aws rds delete-db-subnet-group --db-subnet-group-name $DB_SUBNET_GROUP 2>/dev/null || echo "⚠️ DB subnet group not found or already deleted"
else
    echo "⚠️ No RDS identifier found"
fi

# Step 3: Empty and delete S3 bucket
if [ ! -z "$S3_BUCKET" ]; then
    echo "📦 Step 3: Emptying and deleting S3 bucket..."
    
    # Empty bucket first
    aws s3 rm "s3://$S3_BUCKET" --recursive 2>/dev/null || echo "⚠️ S3 bucket already empty or not found"
    
    # Delete bucket
    aws s3 rb "s3://$S3_BUCKET" 2>/dev/null || echo "⚠️ S3 bucket not found or already deleted"
    echo "✅ S3 bucket deleted: $S3_BUCKET"
else
    echo "⚠️ No S3 bucket found"
fi

# Step 4: Delete IAM resources
if [ ! -z "$IAM_ROLE" ]; then
    echo "🔐 Step 4: Deleting IAM role and policies..."
    
    # Remove role from instance profile
    aws iam remove-role-from-instance-profile \
        --instance-profile-name $IAM_ROLE \
        --role-name $IAM_ROLE 2>/dev/null || echo "⚠️ Role already removed from instance profile"
    
    # Delete instance profile
    aws iam delete-instance-profile --instance-profile-name $IAM_ROLE 2>/dev/null || echo "⚠️ Instance profile not found"
    
    # Delete inline policy
    aws iam delete-role-policy \
        --role-name $IAM_ROLE \
        --policy-name S3AccessPolicy 2>/dev/null || echo "⚠️ Inline policy not found"
    
    # Delete IAM role
    aws iam delete-role --role-name $IAM_ROLE 2>/dev/null || echo "⚠️ IAM role not found"
    
    echo "✅ IAM resources deleted"
else
    echo "⚠️ No IAM role found"
fi

# Step 5: Delete Security Group
if [ ! -z "$SECURITY_GROUP_ID" ]; then
    echo "🔒 Step 5: Deleting security group..."
    
    # Wait a moment to ensure EC2 is fully terminated
    sleep 10
    
    aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID 2>/dev/null || echo "⚠️ Security group not found or has dependencies"
    echo "✅ Security group deleted: $SECURITY_GROUP_ID"
else
    echo "⚠️ No security group ID found"
fi

# Step 6: Clean up local files
echo "🧽 Step 6: Cleaning up local files..."
if [ -f "$DEPLOYMENT_FILE" ]; then
    # Create backup before deleting
    cp $DEPLOYMENT_FILE "${DEPLOYMENT_FILE}.backup.$(date +%s)"
    rm $DEPLOYMENT_FILE
    echo "✅ Deployment info file deleted (backup created)"
fi

echo ""
echo "🎉 Cleanup completed successfully!"
echo "💰 All AWS resources have been terminated to avoid charges."
echo ""
echo "📋 Summary:"
echo "   ✅ EC2 instance terminated"
echo "   ✅ RDS database deleted"
echo "   ✅ S3 bucket emptied and deleted"
echo "   ✅ IAM role and policies removed"
echo "   ✅ Security group deleted"
echo "   ✅ Local deployment files cleaned"
echo ""
echo "💡 You can now run ./deploy.sh again to create a fresh deployment."