#!/bin/bash
# Pre-commit hook to prevent accidentally committing hostPath configurations
# Install: cp pre-commit.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🔍 Checking for hostPath configurations..."

# Get list of files being committed
FILES=$(git diff --cached --name-only --diff-filter=ACM | grep -E '.*deployment\.yaml$')

if [ -z "$FILES" ]; then
    echo "✅ No deployment files in commit"
    exit 0
fi

FOUND_HOSTPATH=0

for FILE in $FILES; do
    # Check if file contains hostPath
    if git diff --cached "$FILE" | grep -q "hostPath:"; then
        echo -e "${RED}❌ ERROR: Found hostPath in $FILE${NC}"
        FOUND_HOSTPATH=1
    fi
    
    # Check for local development comments
    if git diff --cached "$FILE" | grep -q "# add this for local dev test\|# commented out to allow hostpath local dev"; then
        echo -e "${RED}❌ ERROR: Found local dev comments in $FILE${NC}"
        FOUND_HOSTPATH=1
    fi
    
    # Check for local paths like /home/username
    if git diff --cached "$FILE" | grep -qE "path: /home/[a-zA-Z0-9_-]+/"; then
        echo -e "${RED}❌ ERROR: Found local filesystem path in $FILE${NC}"
        FOUND_HOSTPATH=1
    fi
done

if [ $FOUND_HOSTPATH -eq 1 ]; then
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  COMMIT BLOCKED: Local development changes detected   ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}These files contain hostPath configurations or local dev changes:${NC}"
    echo ""
    
    for FILE in $FILES; do
        if git diff --cached "$FILE" | grep -q "hostPath:\|# add this for local dev test\|# commented out to allow hostpath local dev"; then
            echo "  • $FILE"
        fi
    done
    
    echo ""
    echo -e "${YELLOW}To fix this:${NC}"
    echo ""
    echo "  1. Restore original files:"
    echo "     ./localdev.py --restore"
    echo ""
    echo "  2. Or unstage these files:"
    echo "     git reset HEAD <file>"
    echo ""
    echo "  3. Or verify files are marked with skip-worktree:"
    echo "     ./localdev.py --check-git-status"
    echo ""
    echo "  4. If you really need to commit these changes (careful!):"
    echo "     git commit --no-verify"
    echo ""
    exit 1
fi

echo "✅ No hostPath configurations found - commit allowed"
exit 0