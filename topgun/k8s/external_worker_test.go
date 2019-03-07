package k8s_test

import (
	"fmt"
	"time"

	"github.com/onsi/gomega/gexec"

	. "github.com/concourse/concourse/topgun"
	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
)

var _ = Describe("team external workers", func() {
	//TODO: 1. create a chart with worker keys
	// 2. add public key to web
	// 3. run fly workers and make sure it registered correctly

	var (
		proxySession *gexec.Session
		releaseName  string
		namespace    string
		atcEndpoint  string
	)

	BeforeEach(func() {
		releaseName = fmt.Sprintf("topgun-ew-%d-%d", GinkgoRandomSeed(), GinkgoParallelNode())
		namespace = releaseName

		helmArgs := []string{
			"--set=concourse.web.gc.interval=300ms",
			"--set=concourse.web.tsa.heartbeatInterval=300ms",
			"--set=worker.replicas=1",
			"--set=concourse.worker.baggageclaim.driver=overlay",
		}
		deployConcourseChart(releaseName,
			// TODO: https://github.com/concourse/concourse/issues/2827
			helmArgs...)

		configMapCreationArgs := []string{
			"create",
			"configmap",
			"worker-public-key",
			"--namespace=" + namespace,
			`--from-literal=`,
		}

		Run(nil, "kubectl", configMapCreationArgs...)

		waitAllPodsInNamespaceToBeReady(namespace)

		By("Creating the web proxy")
		proxySession, atcEndpoint = startPortForwarding(namespace, releaseName+"-web", "8080")

		By("Logging in")
		fly.Login("test", "test", atcEndpoint)

		By("waiting for a running worker")
		Eventually(func() []Worker {
			return getRunningWorkers(fly.GetWorkers())
		}, 2*time.Minute, 10*time.Second).
			ShouldNot(HaveLen(0))
	})

	AfterEach(func() {
		helmDestroy(releaseName)
		Wait(Start(nil, "kubectl", "delete", "namespace", namespace, "--wait=false"))
		Wait(proxySession.Interrupt())
	})

})
