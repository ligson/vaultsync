package integration

import "testing"

func TestFullBackendMVPFlow(t *testing.T) {
	t.Run("auth", TestRegisterAndLogin)
	t.Run("device", TestRegisterDevice)
	t.Run("sync_root", TestRegisterAndManageSyncRoots)
	t.Run("upload_and_download", TestListChangesAndDownloadCiphertext)
}
