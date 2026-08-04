package repo

import (
	"fmt"
	"math/rand"
	"runtime"
	"testing"

	"github.com/mr-andreas/replycant/server/manifest"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func BenchmarkCommit_AddNewFiles(b *testing.B) {
	batchSize := []int{1, 10, 100, 1000, 10000}
	for _, size := range batchSize {
		b.Run(fmt.Sprintf("BatchSize%d", size), func(b *testing.B) {
			mockRegistry := manifest.NewRegistry()
			mockRegistry.Register("github.com/mr-andreas/replycant/server/repo", &testManifest{})

			ctx := newTestContext(b)
			r, err := Init(mockRegistry, ctx.Dir)
			if err != nil {
				b.Fatal(err)
			}

			b.Log("Using git dir", ctx.Dir, b.N, "commits")

			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				// if i%110 == 1 {
				// 	gcStart := time.Now()
				// 	cmd := exec.Command("git", "gc")
				// 	cmd.Dir = ctx.Dir
				// 	if err := cmd.Run(); err != nil {
				// 		b.Fatal(err)
				// 	}
				// 	b.Log("GC took", time.Since(gcStart))
				// }
				// start := time.Now()

				ops := make([]Operation, size)
				for j := 0; j < size; j++ {
					m := &testManifest{
						ID:      fmt.Sprintf("foo-%d-%d", i, j),
						ANumber: 15,
					}
					ops[j] = Operation{
						Type:     OpTypeAdd,
						Manifest: m,
					}
				}

				err = r.Commit(ops)
				if err != nil {
					b.Fatal(err)
				}

				// b.Log("Op took", time.Since(start))
			}
			b.ReportMetric(float64(b.N)/float64(b.Elapsed().Seconds()), "commits/s")
			b.ReportMetric(float64(b.N*size)/float64(b.Elapsed().Seconds()), "files/s")
		})
	}
}

// Runs with a baseline of 1000 or 10000 files and then modifies 1% or 10% of
// those files
func BenchmarkCommit_ModifyFiles(b *testing.B) {
	baseSizes := []int{1000, 10000}
	modifyPercentages := []int{1, 10}
	for _, baseSize := range baseSizes {
		b.Run(fmt.Sprintf("BaseSize%d", baseSize), func(b *testing.B) {
			for _, modifyPercentage := range modifyPercentages {
				b.Run(fmt.Sprintf("Modify%dPercent", modifyPercentage), func(b *testing.B) {
					modifyCount := baseSize * modifyPercentage / 100

					mockRegistry := manifest.NewRegistry()
					mockRegistry.Register("github.com/mr-andreas/replycant/server/repo", &testManifest{})

					ctx := newTestContext(b)
					r := ctx.initRepoWithFiles(b, baseSize)

					b.ResetTimer()

					// Make sure we do exactly the same modifications every time
					random := rand.NewSource(1234)

					for i := 0; i < b.N; i++ {
						ops := make([]Operation, modifyCount)
						for j := 0; j < modifyCount; j++ {
							m := &testManifest{
								ID:      fmt.Sprintf("foo-%d", random.Int63()%int64(baseSize)),
								ANumber: int(random.Int63()),
							}
							ops[j] = Operation{
								Type:     OpTypeAdd,
								Manifest: m,
							}
						}

						err := r.Commit(ops)
						if err != nil {
							b.Fatal(err)
						}

						// b.Log("Op took", time.Since(start))
					}
					b.ReportMetric(float64(b.N)/float64(b.Elapsed().Seconds()), "commits/s")
					b.ReportMetric(float64(b.N*modifyCount)/float64(b.Elapsed().Seconds()), "files/s")
				})
			}
		})
	}
}

func (ctx *testContext) initRepoWithFiles(b *testing.B, nrFiles int) *Repo {
	mockRegistry := manifest.NewRegistry()
	mockRegistry.Register("github.com/mr-andreas/replycant/server/repo", &testManifest{})

	r, err := Init(mockRegistry, ctx.Dir)
	if err != nil {
		b.Fatal(err)
	}

	b.Log("Using git dir", ctx.Dir, b.N, "commits")

	ops := make([]Operation, nrFiles)
	for i := 0; i < nrFiles; i++ {
		m := &testManifest{
			ID:      fmt.Sprintf("foo-%d", i),
			ANumber: 15,
		}
		ops[i] = Operation{
			Type:     OpTypeAdd,
			Manifest: m,
		}
	}

	err = r.Commit(ops)
	if err != nil {
		b.Fatal(err)
	}

	return r
}

func BenchmarkLoadManifests(b *testing.B) {
	mockRegistry := manifest.NewRegistry()
	mockRegistry.Register("github.com/mr-andreas/replycant/server/repo", &testBigManifest{})

	ctx := newTestContext(b)
	r, err := Init(mockRegistry, ctx.Dir)
	if err != nil {
		b.Fatal(err)
	}

	b.Log("Using git dir", ctx.Dir, b.N, "manifests")

	array := make([]string, 30)
	for i := 0; i < 30; i++ {
		array[i] = fmt.Sprintf("array-entry-%d", i)
	}

	ops := make([]Operation, b.N)
	for i := 0; i < b.N; i++ {
		m := &testBigManifest{
			ID:          fmt.Sprintf("foo-%d", i),
			StringArray: array,
		}
		ops[i] = Operation{
			Type:     OpTypeAdd,
			Manifest: m,
		}
	}

	err = r.Commit(ops)
	if err != nil {
		b.Fatal(err)
	}

	b.ResetTimer()
	b.ReportAllocs()

	m, loadErr := r.LoadAllManifests()
	require.Nil(b, loadErr)

	var memStats runtime.MemStats
	runtime.ReadMemStats(&memStats)
	b.ReportMetric(float64(memStats.Alloc)/1024/1024, "MB")

	assert.Len(b, m["github.com/mr-andreas/replycant/server/repo/testBigManifest"], b.N)
}
