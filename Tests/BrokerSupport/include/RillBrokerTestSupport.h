#ifndef RILL_BROKER_TEST_SUPPORT_H
#define RILL_BROKER_TEST_SUPPORT_H
void *RillKafkaFixtureCreate(void);
const char *RillKafkaFixtureBootstrap(void *fixture);
void RillKafkaFixtureDestroy(void *fixture);
#endif
