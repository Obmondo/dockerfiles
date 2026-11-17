package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"time"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"
	"github.com/samber/oops"
	v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

type Config struct {
	HCloudToken string

	FloatingIPName string

	CRONINterval time.Duration
}

const (
	EgressGatewayLabelKey   = "kubeaid.io/egress-gateway"
	EgressGatewayLabelValue = ""
)

const EgressNodeLabeller = "egress-node-labeller"

const (
	FlagNameKubeContext    = "kube-context"
	FlagNameHCloudToken    = "hcloud-token"
	FlagNameFloatingIPName = "floating-ip-name"
	FlagNameCRONInterval   = "cron-interval"
)

var (
	kubeContext,

	hcloudToken,

	floatingIPName string

	cronInterval time.Duration
)

func main() {
	// Parse CLI flags.
	flag.StringVar(&hcloudToken, FlagNameHCloudToken, "", "HCloud token")
	flag.StringVar(&floatingIPName, FlagNameFloatingIPName, "", "Floating IP name")
	flag.DurationVar(&cronInterval, FlagNameCRONInterval, time.Minute, "CRON interval")
	flag.StringVar(&kubeContext, FlagNameKubeContext, "", "Kubeconfig context to use (for local runs only)")
	flag.Parse()

	ctx := context.Background()

	err := run(ctx)
	if err != nil {
		fmt.Printf("Error : %v", err)
	}
}

func run(ctx context.Context) error {
	// Create HCloud client.
	hcloudClient := hcloud.NewClient(
		hcloud.WithToken(hcloudToken))

	// Create Kubernetes API server client.
	kubeconfig, err := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		clientcmd.NewDefaultClientConfigLoadingRules(),
		&clientcmd.ConfigOverrides{CurrentContext: kubeContext},
	).ClientConfig()
	if err != nil {
		return oops.Wrapf(err, "Failed getting kubeconfig")
	}

	clusterClient, err := kubernetes.NewForConfig(kubeconfig)
	if err != nil {
		return oops.Wrapf(err, "Failed getting Kubernetes API server client")
	}

	ticker := time.NewTicker(cronInterval)
	defer ticker.Stop()
	for {
		// Get the Floating IP details.
		floatingIP, _, err := hcloudClient.FloatingIP.GetByName(ctx, floatingIPName)
		if err != nil {
			return oops.Wrapf(err, "Failed getting Floating IP details")
		}

		// Get the ID of the server to which the Floating IP is attached.
		floatingIPOwnerID := floatingIP.Server.ID
		slog.InfoContext(ctx, "Floating IP attached to server", slog.Int64("id", floatingIPOwnerID))

		// Every HCloud based node has a spec.providerID field managed by HCloud Cloud Controller
		// Manager (CCM). We determine the spec.providerID for the node to which the Floating IP is
		// attached.
		floatingIPOwnerProviderID := fmt.Sprintf("hcloud://%d", floatingIPOwnerID)

		// List all the HCloud based nodes.
		nodes, err := clusterClient.CoreV1().Nodes().List(ctx, v1.ListOptions{
			LabelSelector: "instance.hetzner.cloud/provided-by=cloud",
		})
		if err != nil {
			return oops.Wrapf(err, "Failed listing HCloud based nodes")
		}

		// Go through the nodes.
		// While doing so, add the label to the node having that providerID. And, remove it from the
		// remaining nodes (if present).
		for _, node := range nodes.Items {
			switch node.Spec.ProviderID {
			// The Floating IP is attached to this node.
			// So, we apply the label to this node.
			case floatingIPOwnerProviderID:
				slog.InfoContext(ctx, "Applied egress gateway label to egress node",
					slog.String("node", node.Name),
				)
				err := applyLabel(ctx, EgressGatewayLabelKey, new(EgressGatewayLabelValue), node.Name, clusterClient)
				if err != nil {
					return err
				}

			// Remove the label from this node (if present).
			default:
				slog.InfoContext(ctx, "Ensured egress gateway label is removed from node",
					slog.String("node", node.Name),
				)
				err := applyLabel(ctx, EgressGatewayLabelKey, nil, node.Name, clusterClient)
				if err != nil {
					return err
				}
			}
		}

		select {
		case <-ctx.Done():
			return nil

		case <-ticker.C:
		}
	}
}

// Applies the given label to the given node.
func applyLabel(ctx context.Context,
	labelKey string, labelValue *string,
	nodeName string,
	clusterClient *kubernetes.Clientset,
) error {
	patch, err := json.Marshal(map[string]any{
		"metadata": map[string]any{
			"labels": map[string]*string{labelKey: labelValue},
		},
	})
	if err != nil {
		return oops.Wrapf(err, "Failed preparing patch for applying egress gateway label to node")
	}

	_, err = clusterClient.CoreV1().Nodes().Patch(ctx, nodeName,
		types.MergePatchType, patch, v1.PatchOptions{FieldManager: EgressNodeLabeller},
	)
	if err != nil {
		return oops.Wrapf(err, "Failed applying egress gateway label to node")
	}

	return nil
}
