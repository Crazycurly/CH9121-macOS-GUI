#ifndef CH9121_CNET_H
#define CH9121_CNET_H
#include <stdint.h>
#include <stddef.h>

typedef struct {
    char name[64];
    char address[16];
    char netmask[16];
    uint8_t mac[6];
    uint32_t index;
} ch_adapter;

int ch_list_adapters(ch_adapter *out, int capacity, char *error, size_t error_size);
int ch_udp_open(uint32_t interface_index, uint16_t port, char *error, size_t error_size);
int ch_udp_send(int fd, uint32_t interface_index, const char *source_ip, const char *destination_ip,
                uint16_t destination_port, const uint8_t *bytes, size_t size, char *error, size_t error_size);
/* Returns bytes received, zero on timeout/filter, -1 on error. */
int ch_udp_receive(int fd, uint32_t interface_index, uint8_t *bytes, size_t capacity,
                   int timeout_ms, uint16_t *source_port, char *source_ip,
                   char *error, size_t error_size);
uint16_t ch_udp_local_port(int fd);
void ch_udp_close(int fd);
#endif
