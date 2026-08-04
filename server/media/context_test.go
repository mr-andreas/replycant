package media

import (
	"testing"

	"github.com/mr-andreas/replycant/server/test"
)

type testContext struct {
	*test.Context
}

func newTestContext(t testing.TB) *testContext {
	tc := &testContext{
		Context: test.NewContext(t),
	}
	tc.Registry.Register("github.com/mr-andreas/replycant/server/media", &Original{})

	return tc
}
