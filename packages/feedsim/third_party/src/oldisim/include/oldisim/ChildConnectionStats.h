// Copyright 2015 Google Inc. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
#pragma once

#include <inttypes.h>

#include <algorithm>
#include <map>
#include <set>
#include <vector>

#include "oldisim/Log.h"
#include "oldisim/LogHistogramSampler.h"
#include "oldisim/Query.h"
#include "oldisim/Response.h"
#include "oldisim/Util.h"

// Enable timing tracking for PageRank operations
// Uncomment the line below to enable timing tracking
// #define PASS_PAGERANK_HANDLER_DURATION_TO_RESPONSE

namespace oldisim {

class ChildConnectionStats {
 public:
  explicit ChildConnectionStats(const std::set<uint32_t>& query_types) {
    const int kHistogramBins = 2000;
    for (auto type : query_types) {
      // query_samplers_.emplace(type, std::unique_ptr<LogHistogramSampler>(new
      // LogHistogramSampler(kHistogramBins)));
      query_samplers_.insert(
          std::make_pair(type, LogHistogramSampler(kHistogramBins)));
      query_processing_time_samplers_.insert(
          std::make_pair(type, LogHistogramSampler(kHistogramBins)));
#ifdef PASS_PAGERANK_HANDLER_DURATION_TO_RESPONSE
      total_handler_duration_samplers_.insert(
          std::make_pair(type, LogHistogramSampler(kHistogramBins)));
      pagerank_duration_samplers_.insert(
          std::make_pair(type, LogHistogramSampler(kHistogramBins)));
      sleep_io_duration_samplers_.insert(
          std::make_pair(type, LogHistogramSampler(kHistogramBins)));
      compression_duration_samplers_.insert(
          std::make_pair(type, LogHistogramSampler(kHistogramBins)));
      pointer_chase_duration_samplers_.insert(
          std::make_pair(type, LogHistogramSampler(kHistogramBins)));
      response_generation_duration_samplers_.insert(
          std::make_pair(type, LogHistogramSampler(kHistogramBins)));
#endif
      tx_bytes_[type] = 0;
      rx_bytes_[type] = 0;
      query_counts_[type] = 0;
      dropped_requests_[type] = 0;
    }
    start_time_ = GetTimeAccurateNano();
    elapsed_time_ = 0;
  }

  uint64_t start_time_;
  uint64_t end_time_;
  std::map<uint32_t, LogHistogramSampler> query_samplers_;
  std::map<uint32_t, LogHistogramSampler> query_processing_time_samplers_;
#ifdef PASS_PAGERANK_HANDLER_DURATION_TO_RESPONSE
  std::map<uint32_t, LogHistogramSampler> total_handler_duration_samplers_;
  std::map<uint32_t, LogHistogramSampler> pagerank_duration_samplers_;
  std::map<uint32_t, LogHistogramSampler> sleep_io_duration_samplers_;
  std::map<uint32_t, LogHistogramSampler> compression_duration_samplers_;
  std::map<uint32_t, LogHistogramSampler> pointer_chase_duration_samplers_;
  std::map<uint32_t, LogHistogramSampler> response_generation_duration_samplers_;
#endif
  std::map<uint32_t, uint64_t> tx_bytes_;
  std::map<uint32_t, uint64_t> rx_bytes_;
  std::map<uint32_t, uint64_t> query_counts_;
  std::map<uint32_t, uint64_t> dropped_requests_;
  uint64_t elapsed_time_;

  void LogRequest(const Query& request) {
    assert(tx_bytes_.count(request.GetType()) > 0);
    assert(query_counts_.count(request.GetType()) > 0);

    tx_bytes_.at(request.GetType()) += request.GetQueryPacketSize();
    query_counts_.at(request.GetType())++;
  }

  void LogResponse(const Query& originating_request, const Response& response) {
    assert(query_samplers_.count(originating_request.GetType()) > 0);
    assert(query_processing_time_samplers_.count(
               originating_request.GetType()) > 0);
    assert(tx_bytes_.count(response.GetType()) > 0);

    query_samplers_.at(originating_request.GetType())
        .sample(originating_request.Time() / 1000000.0);
    query_processing_time_samplers_.at(originating_request.GetType())
        .sample(response.GetProcessingTime() / 1000000.0);
    rx_bytes_.at(response.GetType()) += response.GetResponsePacketSize();

#ifdef PASS_PAGERANK_HANDLER_DURATION_TO_RESPONSE
    // Log timing durations (convert from nanoseconds to milliseconds)
    total_handler_duration_samplers_.at(originating_request.GetType())
        .sample(response.GetDurationTotal() / 1000000.0);
    pagerank_duration_samplers_.at(originating_request.GetType())
        .sample(response.GetDurationPageRank() / 1000000.0);
    sleep_io_duration_samplers_.at(originating_request.GetType())
        .sample(response.GetDurationIo() / 1000000.0);
    compression_duration_samplers_.at(originating_request.GetType())
        .sample(response.GetDurationCompression() / 1000000.0);
    pointer_chase_duration_samplers_.at(originating_request.GetType())
        .sample(response.GetDurationChase() / 1000000.0);
    response_generation_duration_samplers_.at(originating_request.GetType())
        .sample(response.GetDurationResponse() / 1000000.0);
#endif
  }

  void LogDroppedRequest(uint32_t request_type) {
    assert(dropped_requests_.count(request_type) > 0);
    dropped_requests_.at(request_type)++;
  }

  void Accumulate(const ChildConnectionStats& cs) {
    assert(cs.query_samplers_.size() == query_samplers_.size());
    assert(cs.query_processing_time_samplers_.size() ==
           query_processing_time_samplers_.size());
    assert(cs.tx_bytes_.size() == tx_bytes_.size());
    assert(cs.rx_bytes_.size() == rx_bytes_.size());
    assert(cs.query_counts_.size() == query_counts_.size());
    assert(cs.dropped_requests_.size() == dropped_requests_.size());

    for (const auto& sampler : cs.query_samplers_) {
      query_samplers_.at(sampler.first).accumulate(sampler.second);
    }

    for (const auto& sampler : cs.query_processing_time_samplers_) {
      query_processing_time_samplers_.at(sampler.first)
          .accumulate(sampler.second);
    }

#ifdef PASS_PAGERANK_HANDLER_DURATION_TO_RESPONSE
    for (const auto& sampler : cs.total_handler_duration_samplers_) {
      total_handler_duration_samplers_.at(sampler.first).accumulate(sampler.second);
    }
    for (const auto& sampler : cs.pagerank_duration_samplers_) {
      pagerank_duration_samplers_.at(sampler.first).accumulate(sampler.second);
    }
    for (const auto& sampler : cs.sleep_io_duration_samplers_) {
      sleep_io_duration_samplers_.at(sampler.first).accumulate(sampler.second);
    }
    for (const auto& sampler : cs.compression_duration_samplers_) {
      compression_duration_samplers_.at(sampler.first).accumulate(sampler.second);
    }
    for (const auto& sampler : cs.pointer_chase_duration_samplers_) {
      pointer_chase_duration_samplers_.at(sampler.first).accumulate(sampler.second);
    }
    for (const auto& sampler : cs.response_generation_duration_samplers_) {
      response_generation_duration_samplers_.at(sampler.first).accumulate(sampler.second);
    }
#endif

    for (const auto& stat : cs.tx_bytes_) {
      tx_bytes_[stat.first] += stat.second;
    }

    for (const auto& stat : cs.rx_bytes_) {
      rx_bytes_[stat.first] += stat.second;
    }

    for (const auto& stat : cs.query_counts_) {
      query_counts_[stat.first] += stat.second;
    }

    for (const auto& stat : cs.dropped_requests_) {
      dropped_requests_[stat.first] += stat.second;
    }

    elapsed_time_ += cs.elapsed_time_;
  }

  void LogElapsedTime() {
    end_time_ = GetTimeAccurateNano();
    elapsed_time_ = end_time_ - start_time_;
  }

  void Reset() {
    for (const auto& stat : query_samplers_) {
      query_samplers_.at(stat.first).Reset();
      query_processing_time_samplers_.at(stat.first).Reset();
#ifdef PASS_PAGERANK_HANDLER_DURATION_TO_RESPONSE
      total_handler_duration_samplers_.at(stat.first).Reset();
      pagerank_duration_samplers_.at(stat.first).Reset();
      sleep_io_duration_samplers_.at(stat.first).Reset();
      compression_duration_samplers_.at(stat.first).Reset();
      pointer_chase_duration_samplers_.at(stat.first).Reset();
      response_generation_duration_samplers_.at(stat.first).Reset();
#endif
      tx_bytes_[stat.first] = 0;
      rx_bytes_[stat.first] = 0;
      query_counts_[stat.first] = 0;
      dropped_requests_[stat.first] = 0;
    }
    start_time_ = GetTimeAccurateNano();
    elapsed_time_ = 0;
  }
};
}  // namespace oldisim
