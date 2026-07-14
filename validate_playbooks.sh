#!/bin/bash
# Ansible Playbook Validation Script

set -e

PLAYBOOK_DIR="$(dirname "$0")/playbooks"
PLAYBOOKS=("qupath.yml" "pixi-ai-tools.yml")

echo "=========================================="
echo "Ansible Playbook Validation"
echo "=========================================="
echo ""

# Check if ansible is installed
if ! command -v ansible-playbook &> /dev/null; then
    echo "❌ ERROR: ansible-playbook is not installed"
    echo "Install with: pip install ansible"
    exit 1
fi
echo "✓ Ansible is installed"

# Check if ansible-lint is installed (optional)
if command -v ansible-lint &> /dev/null; then
    LINT_AVAILABLE=true
    echo "✓ ansible-lint is available"
else
    LINT_AVAILABLE=false
    echo "⚠ ansible-lint not found (optional - install with: pip install ansible-lint)"
fi

# Check if yamllint is installed (optional)
if command -v yamllint &> /dev/null; then
    YAMLLINT_AVAILABLE=true
    echo "✓ yamllint is available"
else
    YAMLLINT_AVAILABLE=false
    echo "⚠ yamllint not found (optional - install with: pip install yamllint)"
fi

echo ""
echo "=========================================="
echo "Running Validation Checks"
echo "=========================================="
echo ""

# Validate each playbook
for playbook in "${PLAYBOOKS[@]}"; do
    playbook_path="$PLAYBOOK_DIR/$playbook"
    
    if [ ! -f "$playbook_path" ]; then
        echo "⚠ Skipping $playbook (file not found)"
        continue
    fi
    
    echo "Validating: $playbook"
    echo "------------------------------------------"
    
    # 1. YAML syntax check with yamllint
    if [ "$YAMLLINT_AVAILABLE" = true ]; then
        echo "  [1/3] Running yamllint..."
        if yamllint "$playbook_path" 2>&1; then
            echo "      ✓ YAML syntax is valid"
        else
            echo "      ⚠ YAML linting found issues"
        fi
    fi
    
    # 2. Ansible syntax check
    echo "  [2/3] Running ansible-playbook --syntax-check..."
    if ansible-playbook --syntax-check "$playbook_path" 2>&1; then
        echo "      ✓ Ansible syntax is valid"
    else
        echo "      ❌ Ansible syntax check failed"
        exit 1
    fi
    
    # 3. Ansible-lint (best practices)
    if [ "$LINT_AVAILABLE" = true ]; then
        echo "  [3/3] Running ansible-lint..."
        if ansible-lint "$playbook_path" 2>&1; then
            echo "      ✓ Ansible linting passed"
        else
            echo "      ⚠ Ansible lint found issues (see above)"
        fi
    fi
    
    echo ""
done

echo "=========================================="
echo "Validation Complete!"
echo "=========================================="
echo ""
echo "Additional validation options:"
echo "  • Dry-run test: ansible-playbook --check <playbook.yml>"
echo "  • Show diff: ansible-playbook --check --diff <playbook.yml>"
echo "  • List tasks: ansible-playbook --list-tasks <playbook.yml>"
echo "  • List tags: ansible-playbook --list-tags <playbook.yml>"
echo ""
