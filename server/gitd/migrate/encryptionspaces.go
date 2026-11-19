package migrate

import (
	"fmt"
	"sort"
	"strings"

	"github.com/mr-andreas/replycant/pkg/gitcrypt"
	"github.com/mr-andreas/replycant/pkg/keyset"
)

// encryptionSpacesFromDeviceSpaces moves each device space under
// encryptionspaces/ and records who the global epochs are already
// wrapped for. File contents stay as they are, so no KEK is needed.
// A library that is already partly moved is refused: guessing would
// hide a repository this server does not understand.
func encryptionSpacesFromDeviceSpaces(tree *Tree) error {
	if len(tree.List(gitcrypt.EncryptionSpacesPrefix)) > 0 {
		return fmt.Errorf("encryptionspaces/ already exists")
	}
	recipientsPath := gitcrypt.GlobalKeySetRoot + "/" + gitcrypt.RecipientsFileName
	if _, err := tree.Read(recipientsPath); err == nil {
		return fmt.Errorf("encryption/recipients.yaml already exists")
	}
	if err := relocateSpaceTree(tree, "manifests"); err != nil {
		return err
	}
	if err := relocateSpaceTree(tree, "binary"); err != nil {
		return err
	}
	names, err := keySetNames(tree)
	if err != nil {
		return err
	}
	body, err := gitcrypt.MarshalRecipientList(gitcrypt.RecipientList{Members: names})
	if err != nil {
		return err
	}
	return tree.Write(recipientsPath, body)
}

func relocateSpaceTree(tree *Tree, kind string) error {
	prefix := kind + "/"
	for _, filePath := range tree.List(prefix) {
		rest := strings.TrimPrefix(filePath, prefix)
		space, tail, ok := strings.Cut(rest, "/")
		if !ok || space == "" || tail == "" {
			return fmt.Errorf("file sits directly under %s", prefix)
		}
		data, err := tree.Read(filePath)
		if err != nil {
			return err
		}
		dest := gitcrypt.EncryptionSpacesPrefix + space + "/" + kind + "/" + tail
		if err := tree.Write(dest, data); err != nil {
			return err
		}
		tree.Delete(filePath)
	}
	return nil
}

func keySetNames(tree *Tree) ([]string, error) {
	var names []string
	for _, filePath := range tree.List("pubkeys/") {
		base := strings.TrimPrefix(filePath, "pubkeys/")
		if strings.Contains(base, "/") || !strings.HasSuffix(base, ".yaml") {
			return nil, fmt.Errorf("unexpected file %s", filePath)
		}
		data, err := tree.Read(filePath)
		if err != nil {
			return nil, err
		}
		parsed, err := keyset.Parse(data)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", filePath, err)
		}
		if keyset.Path(parsed.Metadata.Name) != filePath {
			return nil, fmt.Errorf("%s does not match its name", filePath)
		}
		names = append(names, parsed.Metadata.Name)
	}
	if len(names) == 0 {
		return nil, fmt.Errorf("no key sets")
	}
	sort.Strings(names)
	return names, nil
}
