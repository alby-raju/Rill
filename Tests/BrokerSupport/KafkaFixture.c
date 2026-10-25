/* Independently authored test-only bridge to the selected native client's mock-cluster ABI.
 * No broker/library implementation is copied or shipped as application code here. */
#include "RillBrokerTestSupport.h"
#include <stdlib.h>
#include <stddef.h>
typedef struct rd_kafka_s rd_kafka_t;
typedef struct rd_kafka_mock_cluster_s rd_kafka_mock_cluster_t;
extern void *rd_kafka_conf_new(void);
extern int rd_kafka_conf_set(void *, const char *, const char *, char *, size_t);
extern rd_kafka_t *rd_kafka_new(int, void *, char *, size_t);
extern void rd_kafka_destroy(rd_kafka_t *);
extern rd_kafka_mock_cluster_t *rd_kafka_mock_cluster_new(rd_kafka_t *, int);
extern void rd_kafka_mock_cluster_destroy(rd_kafka_mock_cluster_t *);
extern const char *rd_kafka_mock_cluster_bootstraps(const rd_kafka_mock_cluster_t *);
extern int rd_kafka_mock_topic_create(rd_kafka_mock_cluster_t *, const char *, int, int);
struct fixture { rd_kafka_t *client; rd_kafka_mock_cluster_t *cluster; };
void *RillKafkaFixtureCreate(void) {
    struct fixture *value = calloc(1, sizeof(struct fixture));
    if (!value) return NULL;
    char error[512] = {0}; void *config = rd_kafka_conf_new();
    rd_kafka_conf_set(config, "log_level", "0", error, sizeof(error));
    value->client = rd_kafka_new(0, config, error, sizeof(error));
    if (!value->client) { free(value); return NULL; }
    value->cluster = rd_kafka_mock_cluster_new(value->client, 1);
    if (!value->cluster) { rd_kafka_destroy(value->client); free(value); return NULL; }
    if (rd_kafka_mock_topic_create(value->cluster, "rill-fixture", 1, 1) != 0) { RillKafkaFixtureDestroy(value); return NULL; }
    return value;
}
const char *RillKafkaFixtureBootstrap(void *pointer) { struct fixture *value = pointer; return rd_kafka_mock_cluster_bootstraps(value->cluster); }
void RillKafkaFixtureDestroy(void *pointer) { if (!pointer) return; struct fixture *value = pointer; rd_kafka_mock_cluster_destroy(value->cluster); rd_kafka_destroy(value->client); free(value); }
