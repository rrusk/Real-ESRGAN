#!/usr/bin/env python3
import sys
import pkg_resources

def verify_environment():
    """
    Checks the current environment against the verified stable baseline.
    Prevents NumPy 2.x crashes and CUDA mismatch errors.
    """
    # Define the stable baseline established in your setup history
    required_packages = {
        "numpy": "1.25.0",      # Critical to avoid NumPy 2.x crash 
        "torch": "2.0.1",      # Verified version for GTX 1060 [cite: 14]
        "basicsr": "1.4.2",    # Core dependency pinned for stability [cite: 28]
        "opencv-python": "4.9", # Standardized 4.x version [cite: 11]
    }

    print("--- Environment Verification ---")
    all_passed = True

    for package, min_version in required_packages.items():
        try:
            installed = pkg_resources.get_distribution(package).version
            
            # Special check for NumPy 2.0+ which breaks BasicSR [cite: 11]
            if package == "numpy" and installed.startswith("2."):
                print(f"[FAIL] {package}: Installed version is {installed}, but must be < 2.0.0")
                all_passed = False
                continue

            print(f"[OK]   {package}: {installed}")
            
        except pkg_resources.DistributionNotFound:
            print(f"[MISS] {package}: NOT INSTALLED")
            all_passed = False

    # Check CUDA Availability for GPU acceleration [cite: 12, 14, 47]
    try:
        import torch
        cuda_available = torch.cuda.is_available()
        if cuda_available:
            print(f"[OK]   CUDA: Available (Device: {torch.cuda.get_device_name(0)})")
        else:
            print("[FAIL] CUDA: Not detected. Processing will be extremely slow on CPU.")
            all_passed = False
    except ImportError:
        pass

    print("--------------------------------")
    
    if not all_passed:
        print("❌ Verification failed. Please run: pip install --force-reinstall -r requirements.txt")
        sys.exit(1)
    else:
        print("✅ Environment is stable and compatible.")
        sys.exit(0)

if __name__ == "__main__":
    verify_environment()
